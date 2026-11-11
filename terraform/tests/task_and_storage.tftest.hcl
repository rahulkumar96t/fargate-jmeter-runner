mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  target_domains = ["perf.example.com"]
}

run "default_size_is_registered_in_the_task_definition" {
  assert {
    condition     = aws_ecs_task_definition.jmeter.cpu == "2048" && aws_ecs_task_definition.jmeter.memory == "8192"
    error_message = "Size M must be 2 vCPU / 8 GiB."
  }

  assert {
    condition     = aws_ecs_task_definition.jmeter.family == "jmeter-jmeter"
    error_message = "Unexpected task definition family."
  }

  assert {
    condition     = aws_ecs_task_definition.jmeter.requires_compatibilities == toset(["FARGATE"]) && aws_ecs_task_definition.jmeter.network_mode == "awsvpc"
    error_message = "The task must be a Fargate awsvpc task."
  }
}

run "size_xl_maps_to_8_vcpu" {
  variables {
    default_injector_size = "XL"
  }

  assert {
    condition     = aws_ecs_task_definition.jmeter.cpu == "8192" && aws_ecs_task_definition.jmeter.memory == "32768"
    error_message = "Size XL must be 8 vCPU / 32 GiB."
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.LoadDefaults.Result.defaults.size == "XL"
    error_message = "Runs without a size must default to default_injector_size."
  }
}

run "every_size_is_rendered_into_the_state_machine" {
  assert {
    condition = alltrue([
      for size, spec in {
        S  = { cpu = "1024", memory = "4096" }
        M  = { cpu = "2048", memory = "8192" }
        L  = { cpu = "4096", memory = "16384" }
        XL = { cpu = "8192", memory = "32768" }
      } : jsondecode(aws_sfn_state_machine.this.definition).States["Size${size}"].Result == spec
    ])
    error_message = "The Size<N> states must carry the Fargate CPU/memory of each size as strings."
  }
}

run "custom_sizes_are_honoured" {
  variables {
    injector_sizes = {
      S  = { cpu = 512, memory = 2048 }
      M  = { cpu = 1024, memory = 8192 }
      L  = { cpu = 4096, memory = 30720 }
      XL = { cpu = 16384, memory = 65536 }
    }
    default_injector_size = "L"
  }

  assert {
    condition     = aws_ecs_task_definition.jmeter.cpu == "4096" && aws_ecs_task_definition.jmeter.memory == "30720"
    error_message = "Custom size L must be used for the task definition."
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.SizeXL.Result == { cpu = "16384", memory = "65536" }
    error_message = "Custom size XL must be rendered into the state machine."
  }
}

run "container_definition_is_hardened" {
  assert {
    condition     = jsondecode(aws_ecs_task_definition.jmeter.container_definitions)[0].readonlyRootFilesystem == true
    error_message = "The root file system must be read-only."
  }

  assert {
    condition     = [for m in jsondecode(aws_ecs_task_definition.jmeter.container_definitions)[0].mountPoints : m.containerPath] == ["/work"]
    error_message = "/work must be the only writable mount."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.jmeter.container_definitions)[0].linuxParameters.initProcessEnabled == true
    error_message = "An init process must forward StopTask's SIGTERM to the entrypoint."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.jmeter.container_definitions)[0].ulimits[0].softLimit >= 65535
    error_message = "Injectors need a high open-file limit."
  }

  assert {
    condition     = !can(jsondecode(aws_ecs_task_definition.jmeter.container_definitions)[0].memory) && !can(jsondecode(aws_ecs_task_definition.jmeter.container_definitions)[0].cpu)
    error_message = "A container-level limit would cap the per-run task size override."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.jmeter.container_definitions)[0].logConfiguration.options["awslogs-group"] == aws_cloudwatch_log_group.jmeter.name
    error_message = "Container logs must go to the module's log group."
  }
}

run "lifecycle_expires_raw_results_and_reports_separately" {
  variables {
    jtl_retention_days    = 7
    report_retention_days = 90
  }

  assert {
    condition = one([
      for r in aws_s3_bucket_lifecycle_configuration.results.rule : r.expiration[0].days
      if r.filter[0].prefix == "jtl/" && r.status == "Enabled"
    ]) == 7
    error_message = "Raw JTL files must expire after jtl_retention_days."
  }

  assert {
    condition = one([
      for r in aws_s3_bucket_lifecycle_configuration.results.rule : r.expiration[0].days
      if r.filter[0].prefix == "reports/" && r.status == "Enabled"
    ]) == 90
    error_message = "Reports must expire after report_retention_days."
  }

  assert {
    condition = one([
      for r in aws_s3_bucket_lifecycle_configuration.results.rule : r.abort_incomplete_multipart_upload[0].days_after_initiation
      if r.id == "abort-incomplete-multipart-uploads"
    ]) == 1
    error_message = "Incomplete multipart uploads must be cleaned up."
  }

  assert {
    condition = alltrue([
      for r in aws_s3_bucket_lifecycle_configuration.results.rule : r.filter[0].prefix != "plans/"
    ])
    error_message = "Test plans must never expire."
  }
}

run "bucket_is_private_and_encrypted" {
  assert {
    condition = (
      aws_s3_bucket_public_access_block.results.block_public_acls &&
      aws_s3_bucket_public_access_block.results.block_public_policy &&
      aws_s3_bucket_public_access_block.results.ignore_public_acls &&
      aws_s3_bucket_public_access_block.results.restrict_public_buckets
    )
    error_message = "All four public access blocks must be on."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.results.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "Without a KMS key the bucket must use SSE-S3."
  }

  assert {
    condition     = jsondecode(aws_s3_bucket_policy.results.policy).Statement[0].Effect == "Deny" && jsondecode(aws_s3_bucket_policy.results.policy).Statement[0].Condition.Bool["aws:SecureTransport"] == "false"
    error_message = "The bucket policy must deny plain-HTTP access."
  }

  assert {
    condition     = aws_s3_bucket.results.bucket == "jmeter-results-111111111111-eu-central-1"
    error_message = "Unexpected bucket name."
  }
}

run "kms_key_switches_bucket_to_sse_kms" {
  variables {
    kms_key_arn = "arn:aws:kms:eu-central-1:111111111111:key/00000000-0000-0000-0000-000000000000"
  }

  assert {
    condition = (
      one(one(aws_s3_bucket_server_side_encryption_configuration.results.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms" &&
      one(one(aws_s3_bucket_server_side_encryption_configuration.results.rule).apply_server_side_encryption_by_default).kms_master_key_id == var.kms_key_arn
    )
    error_message = "With a KMS key the bucket must use SSE-KMS with that key."
  }

  assert {
    condition     = contains([for s in jsondecode(aws_iam_role_policy.injector.policy).Statement : s.Sid], "UseBucketKey")
    error_message = "Task roles need kms:Decrypt/GenerateDataKey on the bucket key."
  }
}
