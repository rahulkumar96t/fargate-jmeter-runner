locals {
  # Run parameters the execution input may omit. The validation below rejects the
  # empty plan/targetHost defaults, so those two are effectively required.
  run_defaults = {
    plan            = ""
    targetHost      = ""
    injectors       = 1
    size            = var.default_injector_size
    threads         = min(10, var.max_threads_per_injector)
    durationSeconds = min(300, var.max_duration_seconds)
    rampUpSeconds   = 60
    targetProtocol  = "https"
    targetPort      = 443
    thresholds      = var.default_thresholds
    properties      = ""
  }

  # Merged after the input, so a caller cannot override them.
  run_fixed = {
    egressEnabled = var.nat_enabled
  }

  numeric_limits = [
    { name = "Injectors", field = "injectors", min = 1, max = var.max_injectors },
    { name = "Threads", field = "threads", min = 1, max = var.max_threads_per_injector },
    { name = "Duration", field = "durationSeconds", min = 60, max = var.max_duration_seconds },
    { name = "TargetPort", field = "targetPort", min = 1, max = 65535 },
  ]

  # Ordered input checks. Each rule describes INVALID input and routes to a Reject<name>
  # state that records the cause and sends the failure notification, before any task
  # (and any Fargate cost) is started.
  validation_rules = concat(
    [
      {
        name  = "EgressDisabled"
        cause = "The NAT gateway is disabled (nat_enabled = false). Enable it and apply before starting a run."
        rule  = { Variable = "$.egressEnabled", BooleanEquals = false }
      },
      {
        name  = "Plan"
        cause = "plan must be an S3 key of the form plans/<path>.jmx"
        rule = { Not = { And = [
          { Variable = "$.plan", IsString = true },
          { Variable = "$.plan", StringMatches = "plans/*.jmx" },
        ] } }
      },
      {
        name  = "TargetHost"
        cause = "targetHost must match one of the allow-listed target domains: ${join(", ", var.target_domains)}"
        rule = { Not = { And = [
          { Variable = "$.targetHost", IsString = true },
          { Or = [for d in var.target_domains : { Variable = "$.targetHost", StringMatches = d }] },
        ] } }
      },
    ],
    [
      for l in local.numeric_limits : {
        name  = l.name
        cause = "${l.field} must be a number between ${l.min} and ${l.max}"
        rule = { Not = { And = [
          { Variable = "$.${l.field}", IsNumeric = true },
          { Variable = "$.${l.field}", NumericGreaterThanEquals = l.min },
          { Variable = "$.${l.field}", NumericLessThanEquals = l.max },
        ] } }
      }
    ],
    [
      {
        name  = "RampUp"
        cause = "rampUpSeconds must be a number between 0 and durationSeconds"
        rule = { Not = { And = [
          { Variable = "$.rampUpSeconds", IsNumeric = true },
          { Variable = "$.rampUpSeconds", NumericGreaterThanEquals = 0 },
          { Variable = "$.rampUpSeconds", NumericLessThanEqualsPath = "$.durationSeconds" },
        ] } }
      },
      {
        name  = "TargetProtocol"
        cause = "targetProtocol must be http or https"
        rule = { Not = { Or = [
          { Variable = "$.targetProtocol", StringEquals = "http" },
          { Variable = "$.targetProtocol", StringEquals = "https" },
        ] } }
      },
      {
        name  = "Thresholds"
        cause = "thresholds must be a string such as p95>800,errors>1%"
        rule  = { Not = { Variable = "$.thresholds", IsString = true } }
      },
      {
        name  = "Properties"
        cause = "properties must be a string of comma-separated key=value pairs"
        rule  = { Not = { Variable = "$.properties", IsString = true } }
      },
    ],
  )

  validation_choices = [
    for r in local.validation_rules : merge(r.rule, { Next = "Reject${r.name}" })
  ]

  size_choices = [
    for size in sort(keys(var.injector_sizes)) : {
      Variable     = "$.size"
      StringEquals = size
      Next         = "Size${size}"
    }
  ]

  # An injector may take start delay + duration + this long before it is timed out
  # (image pull, JVM start, plan download, result upload).
  injector_timeout_padding_seconds = var.injector_start_delay_seconds + 900
  report_timeout_seconds           = 3600

  state_machine_definition = templatefile("${path.module}/templates/state_machine.asl.json.tftpl", {
    partition                = local.partition
    defaults_json            = jsonencode(local.run_defaults)
    fixed_json               = jsonencode(local.run_fixed)
    validation_choices_json  = jsonencode(local.validation_choices)
    validation_rules         = local.validation_rules
    size_choices_json        = jsonencode(local.size_choices)
    injector_sizes           = var.injector_sizes
    max_injectors            = var.max_injectors
    cluster_arn              = aws_ecs_cluster.this.arn
    task_definition_arn      = aws_ecs_task_definition.jmeter.arn
    container_name           = local.container_name
    subnets_json             = jsonencode(aws_subnet.private[*].id)
    security_groups_json     = jsonencode([aws_security_group.injector.id])
    reporter_role_arn        = aws_iam_role.reporter.arn
    report_cpu               = tostring(var.injector_sizes[var.report_size].cpu)
    report_memory            = tostring(var.injector_sizes[var.report_size].memory)
    report_timeout_seconds   = local.report_timeout_seconds
    injector_timeout_padding = local.injector_timeout_padding_seconds
    start_delay_seconds      = var.injector_start_delay_seconds
    bucket                   = aws_s3_bucket.results.bucket
    topic_arn                = aws_sns_topic.notifications.arn
  })
}

resource "aws_cloudwatch_log_group" "states" {
  name              = "/aws/vendedlogs/states/${var.name}-load-test"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_sfn_state_machine" "this" {
  name       = "${var.name}-load-test"
  role_arn   = aws_iam_role.states.arn
  type       = "STANDARD"
  definition = local.state_machine_definition

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.states.arn}:*"
    include_execution_data = false
    level                  = "ERROR"
  }

  tags = local.tags

  lifecycle {
    precondition {
      condition     = can(jsondecode(local.state_machine_definition))
      error_message = "The rendered state machine definition is not valid JSON; check templates/state_machine.asl.json.tftpl."
    }
  }
}
