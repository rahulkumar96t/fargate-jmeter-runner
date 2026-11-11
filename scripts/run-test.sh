#!/usr/bin/env bash
# Start a distributed JMeter run (one execution of the load-test state machine).
#
#   scripts/run-test.sh -p plans/smoke/smoke.jmx -t perf.example.com \
#     -n 4 -s L -u 200 -d 900 --fail-if 'p95>800' --fail-if 'errors>1%' --wait
#
# Needs the AWS CLI v2 and credentials from the usual chain (env, profile, SSO).
# Exit codes: 0 started (or, with --wait, succeeded), 1 run did not succeed, 2 usage.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
usage: run-test.sh -p PLAN_KEY -t TARGET_HOST [options]

required
  -p, --plan KEY           S3 key of the plan, e.g. plans/smoke/smoke.jmx
  -t, --target HOST        host to load; must be covered by the module's target_domains
  -m, --state-machine ARN  state machine ARN (default: $JMETER_STATE_MACHINE_ARN)

load shape
  -n, --injectors N        number of Fargate injectors (default 1)
  -s, --size S|M|L|XL      injector size (default M)
  -u, --threads N          JMeter threads per injector (default 10)
  -r, --ramp-up SECONDS    ramp-up per injector (default 60)
  -d, --duration SECONDS   test duration (default 300)
      --protocol P         http or https (default https)
      --port N             target port (default 443)
  -J KEY=VALUE             extra JMeter property for the plan (repeatable)

checks and output
  -f, --fail-if EXPR       threshold such as p95>800 or errors>1% (repeatable);
                           without it the module's default_thresholds apply
      --name NAME          run id / execution name (default: <plan>-<UTC timestamp>)
  -b, --bucket NAME        results bucket (default: $JMETER_RESULTS_BUCKET)
      --upload FILE        upload FILE to s3://BUCKET/PLAN_KEY before starting
  -w, --wait               wait for the run; exit 1 unless it succeeded
      --poll SECONDS       status polling interval with --wait (default 30)
      --dry-run            print the execution input and exit
  -h, --help               show this help
EOF
}

log() {
  printf 'run-test.sh: %s\n' "$*" >&2
}

die() {
  log "$*"
  exit 2
}

need_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "option $1 needs a value"
}

state_machine="${JMETER_STATE_MACHINE_ARN:-}"
bucket="${JMETER_RESULTS_BUCKET:-}"
plan=""
target=""
injectors=1
size=M
threads=10
ramp_up=60
duration=300
protocol=https
port=443
thresholds=""
properties=""
name=""
upload=""
wait_for_result=false
poll=30
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p | --plan) need_value "$@" && plan="$2" && shift 2 ;;
    -t | --target) need_value "$@" && target="$2" && shift 2 ;;
    -m | --state-machine) need_value "$@" && state_machine="$2" && shift 2 ;;
    -n | --injectors) need_value "$@" && injectors="$2" && shift 2 ;;
    -s | --size) need_value "$@" && size="$2" && shift 2 ;;
    -u | --threads) need_value "$@" && threads="$2" && shift 2 ;;
    -r | --ramp-up) need_value "$@" && ramp_up="$2" && shift 2 ;;
    -d | --duration) need_value "$@" && duration="$2" && shift 2 ;;
    --protocol) need_value "$@" && protocol="$2" && shift 2 ;;
    --port) need_value "$@" && port="$2" && shift 2 ;;
    -J) need_value "$@" && properties="${properties:+${properties},}$2" && shift 2 ;;
    -f | --fail-if) need_value "$@" && thresholds="${thresholds:+${thresholds},}$2" && shift 2 ;;
    --name) need_value "$@" && name="$2" && shift 2 ;;
    -b | --bucket) need_value "$@" && bucket="$2" && shift 2 ;;
    --upload) need_value "$@" && upload="$2" && shift 2 ;;
    -w | --wait) wait_for_result=true && shift ;;
    --poll) need_value "$@" && poll="$2" && shift 2 ;;
    --dry-run) dry_run=true && shift ;;
    -h | --help) usage && exit 0 ;;
    *) usage >&2 && die "unknown option: $1" ;;
  esac
done

# --- validation ---------------------------------------------------------------
# Mirrors the state machine's own checks so that mistakes fail before any AWS call.
# It also keeps every value JSON-safe: the input is assembled with printf (no jq).

[[ -n "$plan" ]] || die "--plan is required"
if [[ ! "$plan" =~ ^plans/[A-Za-z0-9._/-]+\.jmx$ || "$plan" == *..* ]]; then
  die "--plan must look like plans/<folder>/<plan>.jmx"
fi

[[ -n "$target" ]] || die "--target is required"
target="$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')"
if [[ ! "$target" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z][a-z0-9-]*[a-z0-9]$ ]]; then
  die "--target must be a host name such as perf.example.com (no scheme, port or path)"
fi

for option in "injectors=$injectors" "threads=$threads" "ramp-up=$ramp_up" \
  "duration=$duration" "port=$port" "poll=$poll"; do
  [[ "${option#*=}" =~ ^[0-9]{1,6}$ ]] || die "--${option%%=*} must be a whole number"
done
# Force base 10 so that a value like 08 is not read as octal.
injectors=$((10#$injectors))
threads=$((10#$threads))
ramp_up=$((10#$ramp_up))
duration=$((10#$duration))
port=$((10#$port))
((injectors >= 1)) || die "--injectors must be at least 1"
((threads >= 1)) || die "--threads must be at least 1"
((ramp_up <= duration)) || die "--ramp-up cannot be longer than --duration"
((port >= 1 && port <= 65535)) || die "--port must be between 1 and 65535"

case "$size" in
  S | M | L | XL) ;;
  *) die "--size must be S, M, L or XL" ;;
esac
case "$protocol" in
  http | https) ;;
  *) die "--protocol must be http or https" ;;
esac

IFS=',' read -r -a parts <<<"$thresholds" || true
for part in ${parts[@]+"${parts[@]}"}; do
  if [[ ! "$part" =~ ^[a-z0-9_]+(\>=|\<=|\>|\<)[0-9]+(\.[0-9]+)?(%|ms)?$ ]]; then
    die "invalid --fail-if '$part' (examples: p95>800, errors>1%, rps<50)"
  fi
done

IFS=',' read -r -a parts <<<"$properties" || true
for part in ${parts[@]+"${parts[@]}"}; do
  [[ "$part" =~ ^[A-Za-z0-9_.-]+=[A-Za-z0-9_.:/@+-]*$ ]] || die "invalid -J '$part' (expected key=value)"
done

if [[ -z "$name" ]]; then
  plan_name="$(basename "$plan" .jmx)"
  plan_name="$(printf '%s' "$plan_name" | tr -c 'A-Za-z0-9_-' '-')"
  name="${plan_name:0:60}-$(date -u +%Y%m%dT%H%M%SZ)"
fi
[[ "$name" =~ ^[A-Za-z0-9_-]{1,80}$ ]] || die "--name may contain letters, digits, '-' and '_' (max 80)"

# --- execution input ----------------------------------------------------------

input="$(printf '{"plan":"%s","targetHost":"%s","injectors":%s,"size":"%s","threads":%s,"rampUpSeconds":%s,"durationSeconds":%s,"targetProtocol":"%s","targetPort":%s' \
  "$plan" "$target" "$injectors" "$size" "$threads" "$ramp_up" "$duration" "$protocol" "$port")"
# Omitted keys fall back to the module's defaults (for example default_thresholds).
[[ -z "$thresholds" ]] || input+="$(printf ',"thresholds":"%s"' "$thresholds")"
[[ -z "$properties" ]] || input+="$(printf ',"properties":"%s"' "$properties")"
input+="}"

if $dry_run; then
  printf '%s\n' "$input"
  exit 0
fi

[[ -n "$state_machine" ]] || die "--state-machine (or JMETER_STATE_MACHINE_ARN) is required"

if [[ -n "$upload" ]]; then
  [[ -f "$upload" ]] || die "--upload: no such file: $upload"
  [[ -n "$bucket" ]] || die "--upload needs --bucket (or JMETER_RESULTS_BUCKET)"
  aws s3 cp --only-show-errors "$upload" "s3://${bucket}/${plan}"
  log "uploaded $upload to s3://${bucket}/${plan}"
fi

execution_arn="$(aws stepfunctions start-execution \
  --state-machine-arn "$state_machine" \
  --name "$name" \
  --input "$input" \
  --query executionArn --output text)"
log "started run ${name}"
printf '%s\n' "$execution_arn"

$wait_for_result || exit 0

while :; do
  status="$(aws stepfunctions describe-execution --execution-arn "$execution_arn" --query status --output text)"
  case "$status" in
    RUNNING | PENDING_REDRIVE) sleep "$poll" ;;
    *) break ;;
  esac
done

log "run ${name} finished: ${status}"
if [[ -n "$bucket" ]]; then
  log "report: s3://${bucket}/reports/${name}/index.html"
fi
if [[ "$status" != "SUCCEEDED" ]]; then
  aws stepfunctions describe-execution --execution-arn "$execution_arn" \
    --query '[error, cause]' --output text >&2 || true
  exit 1
fi
