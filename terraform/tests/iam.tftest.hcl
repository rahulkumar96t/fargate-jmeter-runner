mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  target_domains = ["perf.example.com"]
}

run "injector_reads_plans_and_writes_only_raw_results" {
  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.injector.policy).Statement : s.Resource if contains(flatten([s.Action]), "s3:PutObject")
    ])) == toset(["${aws_s3_bucket.results.arn}/jtl/*"])
    error_message = "Injectors may write to jtl/ only."
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.injector.policy).Statement : s.Resource if contains(flatten([s.Action]), "s3:GetObject")
    ])) == toset(["${aws_s3_bucket.results.arn}/plans/*"])
    error_message = "Injectors may read plans/ only."
  }
}

run "reporter_reads_raw_results_and_writes_only_reports" {
  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.reporter.policy).Statement : s.Resource if contains(flatten([s.Action]), "s3:PutObject")
    ])) == toset(["${aws_s3_bucket.results.arn}/reports/*"])
    error_message = "The reporter may write to reports/ only."
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.reporter.policy).Statement : s.Resource if contains(flatten([s.Action]), "s3:GetObject")
    ])) == toset(["${aws_s3_bucket.results.arn}/jtl/*"])
    error_message = "The reporter may read jtl/ only."
  }
}

run "no_wildcard_actions_and_no_kms_without_a_key" {
  assert {
    condition = alltrue(flatten([
      for p in [aws_iam_role_policy.execution, aws_iam_role_policy.injector, aws_iam_role_policy.reporter, aws_iam_role_policy.states] : [
        for s in jsondecode(p.policy).Statement : alltrue([for a in flatten([s.Action]) : !endswith(a, ":*") && a != "*"])
      ]
    ]))
    error_message = "No policy may grant service-wide wildcard actions."
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.injector.policy, "kms:")
    error_message = "KMS permissions must only be granted when kms_key_arn is set."
  }
}

run "state_machine_can_only_run_its_own_task_definition_on_its_cluster" {
  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.states.policy).Statement : s if s.Sid == "RunJmeterTasks"
      ]) == {
      Sid       = "RunJmeterTasks"
      Effect    = "Allow"
      Action    = "ecs:RunTask"
      Resource  = "arn:aws:ecs:eu-central-1:111111111111:task-definition/jmeter-jmeter:*"
      Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
    }
    error_message = "ecs:RunTask must be limited to the jmeter family on the module's cluster."
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.states.policy).Statement : s.Condition if s.Sid == "PassTaskRoles"
    ]) == { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
    error_message = "iam:PassRole must be restricted to ECS tasks."
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.states.policy).Statement : s.Resource if s.Sid == "ReadVerdict"
    ]) == "${aws_s3_bucket.results.arn}/reports/*/verdict.json"
    error_message = "The state machine may only read verdict files."
  }
}

run "roles_trust_their_service_within_the_account" {
  assert {
    condition = alltrue([
      for r in [aws_iam_role.execution, aws_iam_role.injector, aws_iam_role.reporter, aws_iam_role.states] :
      jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "111111111111"
    ])
    error_message = "Every trust policy must pin aws:SourceAccount (confused-deputy protection)."
  }
}
