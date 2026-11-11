#!/usr/bin/env bash
# Entrypoint of the JMeter image.
#
#   run     one injector: download the plan folder from S3, wait for the synchronised
#           start, run `jmeter -n`, upload the JTL and the JMeter log
#   report  download every JTL of the run, merge them, write summary.json and
#           verdict.json, build the HTML dashboard with `jmeter -g`, upload it all
#
# Settings arrive as environment variables from the state machine (see README.md,
# "Container contract"). Compatible with bash 3.2+ so the tests also run on macOS.
set -Eeuo pipefail

readonly MODE="${1:-run}"
readonly WORK_DIR="${WORK_DIR:-/work}"
readonly JMETER_BIN="${JMETER_BIN:-jmeter}"
readonly AWS_BIN="${AWS_BIN:-aws}"
readonly PYTHON_BIN="${PYTHON_BIN:-python3}"
readonly SUMMARY_TOOL="${SUMMARY_TOOL:-/opt/runner/jtl_summary.py}"
readonly RUNNER_PROPERTIES="${RUNNER_PROPERTIES:-/opt/runner/runner.properties}"
# Time JMeter gets on top of the test duration (JVM start, ramp-down, flushing).
readonly JMETER_GRACE_SECONDS="${JMETER_GRACE_SECONDS:-300}"

JMETER_PID=""

log() {
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<'EOF'
usage: entrypoint.sh run|report

  run     run one JMeter injector (needs RESULTS_BUCKET, RUN_ID, PLAN_KEY, TARGET_HOST)
  report  merge the run's JTL files and build the report (needs RESULTS_BUCKET, RUN_ID)
EOF
}

require_env() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || die "environment variable ${name} is required"
  done
}

require_uint() {
  local name
  for name in "$@"; do
    [[ "${!name}" =~ ^[0-9]+$ ]] || die "${name} must be a non-negative integer, got '${!name}'"
  done
}

validate_run_id() {
  # The run id is part of every S3 key of the run; keep it to the execution-name alphabet.
  [[ "$RUN_ID" =~ ^[A-Za-z0-9_-]{1,80}$ ]] || die "RUN_ID '${RUN_ID}' is not a valid run id"
}

s3_uri() {
  printf 's3://%s/%s' "$RESULTS_BUCKET" "$1"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# Sleep until START_AFTER + START_DELAY_SECONDS so injectors that were provisioned
# at different speeds still start their load together.
wait_for_start() {
  [[ -n "${START_AFTER:-}" ]] || return 0
  local start_epoch now remaining
  start_epoch="$("$PYTHON_BIN" -c '
import datetime, sys
print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")).timestamp()))
' "$START_AFTER" 2>/dev/null)" || die "START_AFTER '${START_AFTER}' is not an ISO-8601 timestamp"
  start_epoch=$((start_epoch + START_DELAY_SECONDS))
  now="$(date +%s)"
  remaining=$((start_epoch - now))
  if ((remaining > 0)); then
    log "waiting ${remaining}s for the synchronised start"
    sleep "$remaining"
  else
    log "synchronised start was $((-remaining))s ago; starting now"
  fi
}

forward_signal() {
  log "received $1; stopping JMeter so that partial results can be uploaded"
  if [[ -n "$JMETER_PID" ]]; then
    kill -TERM "$JMETER_PID" 2>/dev/null || true
  fi
}

run_injector() {
  require_env RESULTS_BUCKET RUN_ID PLAN_KEY TARGET_HOST
  validate_run_id
  if [[ ! "$PLAN_KEY" =~ ^plans/[A-Za-z0-9._/-]+\.jmx$ || "$PLAN_KEY" == *..* ]]; then
    die "PLAN_KEY '${PLAN_KEY}' must look like plans/<folder>/<plan>.jmx"
  fi
  : "${INJECTOR_INDEX:=0}" "${INJECTOR_COUNT:=1}" "${THREADS:=1}" "${RAMP_UP_SECONDS:=0}"
  : "${DURATION_SECONDS:=60}" "${TARGET_PROTOCOL:=https}" "${TARGET_PORT:=443}" "${START_DELAY_SECONDS:=0}"
  require_uint INJECTOR_INDEX INJECTOR_COUNT THREADS RAMP_UP_SECONDS DURATION_SECONDS TARGET_PORT START_DELAY_SECONDS

  local plan_dir="${WORK_DIR}/plan" out_dir="${WORK_DIR}/out"
  local plan_prefix="${PLAN_KEY%/*}/"
  local plan_file="${plan_dir}/${PLAN_KEY##*/}"
  local jtl="${out_dir}/injector-${INJECTOR_INDEX}.jtl"
  local jmeter_log="${out_dir}/jmeter-${INJECTOR_INDEX}.log"
  local results_prefix="jtl/${RUN_ID}"
  rm -rf "$plan_dir" "$out_dir"
  mkdir -p "$plan_dir" "$out_dir"

  # The whole folder, so CSV data sets next to the plan resolve by relative path.
  log "downloading $(s3_uri "$plan_prefix")"
  "$AWS_BIN" s3 cp --recursive --only-show-errors "$(s3_uri "$plan_prefix")" "${plan_dir}/"
  [[ -f "$plan_file" ]] || die "plan $(s3_uri "$PLAN_KEY") not found"

  local -a cmd=(
    "$JMETER_BIN" -n
    -t "$plan_file"
    -l "$jtl"
    -j "$jmeter_log"
    -q "$RUNNER_PROPERTIES"
    "-Jthreads=${THREADS}"
    "-Jrampup=${RAMP_UP_SECONDS}"
    "-Jduration=${DURATION_SECONDS}"
    "-Jtarget.host=${TARGET_HOST:?}"
    "-Jtarget.protocol=${TARGET_PROTOCOL}"
    "-Jtarget.port=${TARGET_PORT}"
    "-Jinjector.index=${INJECTOR_INDEX}"
    "-Jinjector.count=${INJECTOR_COUNT}"
    "-Jrun.id=${RUN_ID}"
  )

  # JMETER_PROPERTIES="key=value,other.key=value" becomes -Jkey=value -Jother.key=value.
  local raw pair
  local -a pairs=()
  IFS=',' read -r -a pairs <<<"${JMETER_PROPERTIES:-}" || true
  for raw in ${pairs[@]+"${pairs[@]}"}; do
    pair="$(trim "$raw")"
    [[ -n "$pair" ]] || continue
    if [[ "$pair" != *=* || ! "${pair%%=*}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      die "invalid JMETER_PROPERTIES entry '${pair}' (expected key=value)"
    fi
    cmd+=("-J${pair}")
  done

  # A hung JVM must not keep the task (and the whole run) alive past its budget.
  if command -v timeout >/dev/null 2>&1; then
    cmd=(timeout --kill-after=30 "$((DURATION_SECONDS + JMETER_GRACE_SECONDS))" "${cmd[@]}")
  fi

  wait_for_start
  log "injector $((INJECTOR_INDEX + 1))/${INJECTOR_COUNT}: ${THREADS} threads, ramp-up ${RAMP_UP_SECONDS}s," \
    "duration ${DURATION_SECONDS}s against ${TARGET_PROTOCOL}://${TARGET_HOST}:${TARGET_PORT}"

  local rc=0
  "${cmd[@]}" &
  JMETER_PID=$!
  wait "$JMETER_PID" || rc=$?
  # A trapped signal interrupts `wait`; wait again for JMeter's own exit status.
  if kill -0 "$JMETER_PID" 2>/dev/null; then
    rc=0
    wait "$JMETER_PID" || rc=$?
  fi
  JMETER_PID=""

  if [[ -f "$jmeter_log" ]]; then
    "$AWS_BIN" s3 cp --only-show-errors "$jmeter_log" "$(s3_uri "${results_prefix}/logs/jmeter-${INJECTOR_INDEX}.log")" ||
      log "WARNING: could not upload the JMeter log"
  fi

  local failure=""
  if ((rc == 124)); then
    failure="JMeter ran past duration + ${JMETER_GRACE_SECONDS}s and was stopped"
  elif ((rc != 0)); then
    failure="JMeter exited with status ${rc}"
  elif [[ ! -f "$jtl" || "$(head -n 2 "$jtl" | wc -l | tr -d ' ')" -lt 2 ]]; then
    failure="JMeter recorded no samples; check the plan and the target"
  fi

  if [[ -n "$failure" ]]; then
    # Keep partial results for diagnosis, but under a name the report step ignores:
    # the verdict then counts this injector as missing instead of averaging it in.
    if [[ -f "$jtl" ]]; then
      "$AWS_BIN" s3 cp --only-show-errors "$jtl" "$(s3_uri "${results_prefix}/injector-${INJECTOR_INDEX}.jtl.partial")" ||
        log "WARNING: could not upload partial results"
    fi
    die "$failure"
  fi

  "$AWS_BIN" s3 cp --only-show-errors "$jtl" "$(s3_uri "${results_prefix}/injector-${INJECTOR_INDEX}.jtl")"
  log "uploaded $(s3_uri "${results_prefix}/injector-${INJECTOR_INDEX}.jtl")"
}

build_report() {
  require_env RESULTS_BUCKET RUN_ID
  validate_run_id
  : "${EXPECTED_INJECTORS:=0}"
  require_uint EXPECTED_INJECTORS

  local jtl_dir="${WORK_DIR}/jtl" summary_dir="${WORK_DIR}/summary" report_dir="${WORK_DIR}/report"
  local reports_prefix="reports/${RUN_ID}"
  rm -rf "$jtl_dir" "$summary_dir" "$report_dir"
  mkdir -p "$jtl_dir" "$summary_dir"

  log "downloading $(s3_uri "jtl/${RUN_ID}/")"
  "$AWS_BIN" s3 cp --recursive --only-show-errors --exclude '*' --include 'injector-*.jtl' \
    "$(s3_uri "jtl/${RUN_ID}/")" "${jtl_dir}/"

  local -a args=(
    --out "${summary_dir}/summary.json"
    --verdict-out "${summary_dir}/verdict.json"
    --merged-out "${summary_dir}/merged.jtl"
  )
  if ((EXPECTED_INJECTORS > 0)); then
    args+=(--expect-inputs "$EXPECTED_INJECTORS")
  fi
  if [[ -n "$(trim "${FAIL_IF:-}")" ]]; then
    args+=(--fail-if "$FAIL_IF")
  fi

  # Exit status 1 means "checks failed": that is a result, not an error. The state
  # machine reads the verdict and decides; only status 2 (bad input) stops here.
  local rc=0
  "$PYTHON_BIN" "$SUMMARY_TOOL" "${args[@]}" "$jtl_dir" || rc=$?
  case "$rc" in
    0) log "all checks passed" ;;
    1) log "checks failed; see verdict.json" ;;
    *) die "jtl_summary.py failed with status ${rc}" ;;
  esac

  "$AWS_BIN" s3 cp --only-show-errors "${summary_dir}/summary.json" "$(s3_uri "${reports_prefix}/summary.json")"

  if [[ -f "${summary_dir}/merged.jtl" && "$(head -n 2 "${summary_dir}/merged.jtl" | wc -l | tr -d ' ')" -ge 2 ]]; then
    log "building the HTML dashboard"
    "$JMETER_BIN" -g "${summary_dir}/merged.jtl" -o "$report_dir" -q "$RUNNER_PROPERTIES" -j "${summary_dir}/report.log"
    "$AWS_BIN" s3 cp --recursive --only-show-errors "${report_dir}/" "$(s3_uri "${reports_prefix}/")"
  else
    log "no samples; skipping the HTML dashboard"
  fi

  # Uploaded last: the state machine reads it as soon as this task has stopped.
  "$AWS_BIN" s3 cp --only-show-errors "${summary_dir}/verdict.json" "$(s3_uri "${reports_prefix}/verdict.json")"
  log "report: $(s3_uri "${reports_prefix}/index.html")"
}

main() {
  # TMPDIR points into /work in the image (the root file system is read-only).
  if [[ -n "${TMPDIR:-}" ]]; then
    mkdir -p "$TMPDIR"
  fi
  case "$MODE" in
    run)
      trap 'forward_signal TERM' TERM
      trap 'forward_signal INT' INT
      run_injector
      ;;
    report)
      build_report
      ;;
    -h | --help | help)
      usage
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
}

main "$@"
