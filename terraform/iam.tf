# Four roles, each with only what its step needs:
#   execution  ECS agent: pull the image, write container logs
#   injector   "run" tasks: read plans/, write jtl/
#   reporter   "report" task: read jtl/, write reports/
#   states     state machine: run/stop the two task kinds, read the verdict, notify

locals {
  bucket_arn = aws_s3_bucket.results.arn

  # ARN without the revision, so the state machine may run any revision of the family.
  task_definition_family_arn = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:task-definition/${aws_ecs_task_definition.jmeter.family}:*"
  cluster_tasks_arn          = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:task/${aws_ecs_cluster.this.name}/*"

  kms_statements = var.kms_key_arn == null ? [] : [
    {
      Sid      = "UseBucketKey"
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
      Resource = var.kms_key_arn
    },
  ]
}

resource "aws_iam_role" "execution" {
  name = "${var.name}-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
      },
    ]
  })

  tags = local.tags
}

# Narrower than the AWS managed AmazonECSTaskExecutionRolePolicy, which allows every
# repository and every log group in the account.
resource "aws_iam_role_policy" "execution" {
  name = "pull-image-and-log"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid      = "PullJmeterImage"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = aws_ecr_repository.jmeter.arn
      },
      {
        Sid      = "WriteContainerLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.jmeter.arn}:*"
      },
    ]
  })
}

resource "aws_iam_role" "injector" {
  name = "${var.name}-injector"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
      },
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "injector" {
  name = "read-plans-write-jtl"
  role = aws_iam_role.injector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid       = "ListPlans"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = local.bucket_arn
        Condition = { StringLike = { "s3:prefix" = ["${local.plans_prefix}*"] } }
      },
      {
        Sid      = "ReadPlans"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${local.bucket_arn}/${local.plans_prefix}*"
      },
      {
        Sid      = "WriteRawResults"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "${local.bucket_arn}/${local.jtl_prefix}*"
      },
    ], local.kms_statements)
  })
}

resource "aws_iam_role" "reporter" {
  name = "${var.name}-reporter"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
      },
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "reporter" {
  name = "read-jtl-write-reports"
  role = aws_iam_role.reporter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid       = "ListRawResults"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = local.bucket_arn
        Condition = { StringLike = { "s3:prefix" = ["${local.jtl_prefix}*"] } }
      },
      {
        Sid      = "ReadRawResults"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${local.bucket_arn}/${local.jtl_prefix}*"
      },
      {
        Sid      = "WriteReports"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "${local.bucket_arn}/${local.reports_prefix}*"
      },
    ], local.kms_statements)
  })
}

resource "aws_iam_role" "states" {
  name = "${var.name}-states"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "states.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
      },
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "states" {
  name = "orchestrate-load-test"
  role = aws_iam_role.states.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid       = "RunJmeterTasks"
        Effect    = "Allow"
        Action    = "ecs:RunTask"
        Resource  = local.task_definition_family_arn
        Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
      },
      {
        Sid      = "TrackJmeterTasks"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks", "ecs:StopTask"]
        Resource = local.cluster_tasks_arn
      },
      {
        Sid       = "TagTasksWithRunId"
        Effect    = "Allow"
        Action    = "ecs:TagResource"
        Resource  = local.cluster_tasks_arn
        Condition = { StringEquals = { "ecs:CreateAction" = "RunTask" } }
      },
      {
        Sid      = "PassTaskRoles"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = [aws_iam_role.execution.arn, aws_iam_role.injector.arn, aws_iam_role.reporter.arn]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
      {
        # Managed rule that the .sync integration uses to learn when a task stops.
        Sid      = "SyncIntegrationRule"
        Effect   = "Allow"
        Action   = ["events:PutTargets", "events:PutRule", "events:DescribeRule"]
        Resource = "arn:${local.partition}:events:${local.region}:${local.account_id}:rule/StepFunctionsGetEventsForECSTaskRule"
      },
      {
        Sid      = "ReadVerdict"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${local.bucket_arn}/${local.reports_prefix}*/verdict.json"
      },
      {
        Sid      = "Notify"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.notifications.arn
      },
      {
        # Log delivery APIs do not support resource-level permissions.
        Sid    = "ExecutionLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:DescribeLogGroups",
          "logs:DescribeResourcePolicies",
          "logs:GetLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:UpdateLogDelivery",
        ]
        Resource = "*"
      },
    ], local.kms_statements)
  })
}
