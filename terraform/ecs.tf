resource "aws_ecr_repository" "jmeter" {
  name                 = "${var.name}/jmeter"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.force_destroy

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "jmeter" {
  repository = aws_ecr_repository.jmeter.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the 10 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      },
    ]
  })
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = var.container_insights ? "enabled" : "disabled"
  }

  tags = local.tags
}

# One task definition serves both roles. The state machine overrides the command
# ("run" or "report"), the task size, the task role and the environment per task.
resource "aws_ecs_task_definition" "jmeter" {
  family                   = "${var.name}-jmeter"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.injector_sizes[var.default_injector_size].cpu)
  memory                   = tostring(var.injector_sizes[var.default_injector_size].memory)
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.injector.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  ephemeral_storage {
    size_in_gib = var.ephemeral_storage_gib
  }

  # The only writable path: scratch space on the task's ephemeral storage. The image
  # chowns /work and declares it as a VOLUME, so the non-root user owns the mount.
  volume {
    name = "work"
  }

  container_definitions = jsonencode([
    {
      name                   = local.container_name
      image                  = "${aws_ecr_repository.jmeter.repository_url}:${var.image_tag}"
      essential              = true
      command                = ["run"]
      readonlyRootFilesystem = true
      stopTimeout            = 60

      # A real init as PID 1 forwards SIGTERM (StopTask) to the entrypoint, which then
      # stops JMeter and uploads partial results before the task is killed.
      linuxParameters = { initProcessEnabled = true }

      # No container-level cpu/memory: the task-level size (overridden per run) applies.
      environment = [
        { name = "RESULTS_BUCKET", value = aws_s3_bucket.results.bucket },
        { name = "AWS_REGION", value = local.region },
        { name = "AWS_DEFAULT_REGION", value = local.region },
      ]

      mountPoints = [
        { sourceVolume = "work", containerPath = "/work", readOnly = false },
      ]

      # Every virtual user holds at least one socket.
      ulimits = [
        { name = "nofile", softLimit = 65535, hardLimit = 65535 },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.jmeter.name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "jmeter"
        }
      }
    },
  ])

  tags = local.tags
}
