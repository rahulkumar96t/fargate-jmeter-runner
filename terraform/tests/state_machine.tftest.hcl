mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  name           = "jmeter"
  target_domains = ["perf.example.com", "*.perf.example.com"]
  max_injectors  = 12
}

run "map_fans_out_injectors_concurrently" {
  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.RunInjectors.Type == "Map"
    error_message = "Injectors must be started by a Map state."
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.RunInjectors.MaxConcurrency == 12
    error_message = "MaxConcurrency must equal max_injectors so that every injector runs at the same time."
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.RunInjectors.ItemsPath == "$.derived.injectorIndexes"
    error_message = "The Map must iterate over the computed injector indexes."
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.PlanRun.Parameters["injectorIndexes.$"] == "States.ArrayRange(0, States.MathAdd($.injectors, -1), 1)"
    error_message = "Injector indexes must be 0..injectors-1."
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.RunInjectors.ItemProcessor.States.RunInjector.Resource == "arn:aws:states:::ecs:runTask.sync"
    error_message = "Each injector must be an ecs:runTask.sync task, so the Map waits for it to finish."
  }
}

run "injector_task_overrides" {
  assert {
    condition = (
      jsondecode(aws_sfn_state_machine.this.definition).States.RunInjectors.ItemProcessor.States.RunInjector.Parameters.TaskDefinition == aws_ecs_task_definition.jmeter.arn &&
      jsondecode(aws_sfn_state_machine.this.definition).States.RunInjectors.ItemProcessor.States.RunInjector.Parameters.Cluster == aws_ecs_cluster.this.arn
    )
    error_message = "Injectors must run the module's task definition revision on the module's cluster."
  }

  assert {
    condition = (
      jsondecode(aws_sfn_state_machine.this.definition).States.RunInjectors.ItemProcessor.States.RunInjector.Parameters.Overrides["Cpu.$"] == "$.config.resources.cpu" &&
      jsondecode(aws_sfn_state_machine.this.definition).States.RunInjectors.ItemProcessor.States.RunInjector.Parameters.Overrides["Memory.$"] == "$.config.resources.memory"
    )
    error_message = "Task CPU and memory must be overridden from the resolved injector size."
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.RunInjectors.ItemProcessor.States.RunInjector.Parameters.Overrides.ContainerOverrides[0].Name == "jmeter"
    error_message = "The container override must target the jmeter container."
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.RunInjectors.ItemProcessor.States.RunInjector.Parameters.Overrides.ContainerOverrides[0].Command == ["run"]
    error_message = "Injectors must start the entrypoint in run mode."
  }

  assert {
    condition = toset([
      for e in jsondecode(aws_sfn_state_machine.this.definition).States.RunInjectors.ItemProcessor.States.RunInjector.Parameters.Overrides.ContainerOverrides[0].Environment : e.Name
      ]) == toset([
      "RUN_ID", "PLAN_KEY", "INJECTOR_INDEX", "INJECTOR_COUNT", "THREADS", "RAMP_UP_SECONDS",
      "DURATION_SECONDS", "TARGET_HOST", "TARGET_PROTOCOL", "TARGET_PORT", "JMETER_PROPERTIES",
      "START_AFTER", "START_DELAY_SECONDS",
    ])
    error_message = "Injector environment does not match the entrypoint contract."
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.RunInjectors.ItemProcessor.States.RunInjector.Parameters.NetworkConfiguration.AwsvpcConfiguration.AssignPublicIp == "DISABLED"
    error_message = "Injectors must not get public IPs; all egress goes through the NAT gateway's Elastic IP."
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.RunInjectors.ItemProcessor.States.RunInjector.Parameters.NetworkConfiguration.AwsvpcConfiguration.Subnets == aws_subnet.private[*].id
    error_message = "Injectors must run in the private subnets."
  }
}

run "retry_and_catch" {
  assert {
    condition = alltrue([
      for e in jsondecode(aws_sfn_state_machine.this.definition).States.RunInjectors.ItemProcessor.States.RunInjector.Retry[0].ErrorEquals :
      !contains(["States.ALL", "States.TaskFailed", "States.Timeout"], e)
    ])
    error_message = "A failed or timed-out injector must not be retried; only RunTask API errors are."
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.RunInjectors.ItemProcessor.States.RunInjector.Retry[0].JitterStrategy == "FULL"
    error_message = "Concurrent RunTask retries need jitter."
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.RunInjectors.ItemProcessor.States.RunInjector.Catch[0].Next == "InjectorFailed"
    error_message = "A failed injector must be caught inside the iteration."
  }

  assert {
    condition = alltrue([
      for s in ["RunInjectors", "BuildReport", "LoadVerdict"] :
      jsondecode(aws_sfn_state_machine.this.definition).States[s].Catch[0].ErrorEquals == ["States.ALL"] &&
      jsondecode(aws_sfn_state_machine.this.definition).States[s].Catch[0].Next == "NotifyFailure"
    ])
    error_message = "Map, report and verdict steps must route every error to the failure notification."
  }

  assert {
    condition     = length(jsondecode(aws_sfn_state_machine.this.definition).States.BuildReport.Retry) > 0
    error_message = "The report task must retry RunTask API errors."
  }

  assert {
    condition = alltrue([
      for s in ["NotifySuccess", "NotifyVerdictFailed", "NotifyFailure"] :
      jsondecode(aws_sfn_state_machine.this.definition).States[s].Resource == "arn:aws:states:::sns:publish" &&
      jsondecode(aws_sfn_state_machine.this.definition).States[s].Parameters.TopicArn == aws_sns_topic.notifications.arn &&
      length(jsondecode(aws_sfn_state_machine.this.definition).States[s].Retry) > 0
    ])
    error_message = "Every outcome must be published to the SNS topic with retries."
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.NotifyFailure.Next == "Failed" && jsondecode(aws_sfn_state_machine.this.definition).States.Failed.Type == "Fail"
    error_message = "After the failure notification the execution must fail."
  }
}

run "report_task_uses_reporter_role_and_size" {
  variables {
    report_size = "XL"
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.BuildReport.Parameters.Overrides.TaskRoleArn == aws_iam_role.reporter.arn
    error_message = "The report task must run with the reporter role."
  }

  assert {
    condition = (
      jsondecode(aws_sfn_state_machine.this.definition).States.BuildReport.Parameters.Overrides.Cpu == "8192" &&
      jsondecode(aws_sfn_state_machine.this.definition).States.BuildReport.Parameters.Overrides.Memory == "32768"
    )
    error_message = "The report task must use report_size."
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.BuildReport.Parameters.Overrides.ContainerOverrides[0].Command == ["report"]
    error_message = "The report task must start the entrypoint in report mode."
  }
}

run "validation_rules_render_limits" {
  variables {
    max_duration_seconds     = 1800
    max_threads_per_injector = 500
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.Validate.Choices[0].Next == "RejectEgressDisabled"
    error_message = "The egress check must come first."
  }

  assert {
    condition = contains([
      for c in jsondecode(aws_sfn_state_machine.this.definition).States.Validate.Choices :
      c.Not.And[2].NumericLessThanEquals if c.Next == "RejectInjectors"
    ], 12)
    error_message = "The injector limit must be max_injectors."
  }

  assert {
    condition = contains([
      for c in jsondecode(aws_sfn_state_machine.this.definition).States.Validate.Choices :
      c.Not.And[2].NumericLessThanEquals if c.Next == "RejectDuration"
    ], 1800)
    error_message = "The duration limit must be max_duration_seconds."
  }

  assert {
    condition = contains([
      for c in jsondecode(aws_sfn_state_machine.this.definition).States.Validate.Choices :
      c.Not.And[2].NumericLessThanEquals if c.Next == "RejectThreads"
    ], 500)
    error_message = "The thread limit must be max_threads_per_injector."
  }

  assert {
    condition = [
      for c in jsondecode(aws_sfn_state_machine.this.definition).States.Validate.Choices :
      [for r in c.Not.And[1].Or : r.StringMatches] if c.Next == "RejectTargetHost"
    ][0] == ["perf.example.com", "*.perf.example.com"]
    error_message = "targetHost must be checked against exactly the DNS allow-list."
  }

  assert {
    condition = toset([
      for c in jsondecode(aws_sfn_state_machine.this.definition).States.ResolveSize.Choices : c.StringEquals
    ]) == toset(["S", "M", "L", "XL"])
    error_message = "Exactly the sizes S, M, L and XL must be accepted."
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.ResolveSize.Default == "RejectSize"
    error_message = "An unknown size must be rejected."
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.LoadDefaults.Result.defaults.durationSeconds <= 1800
    error_message = "The default duration must respect max_duration_seconds."
  }
}

# Every transition must point at a state that exists, including Choice branches and
# Catch handlers, at both levels of the definition.
run "definition_has_no_dangling_transitions" {
  assert {
    condition = alltrue(flatten([
      for states in [
        jsondecode(aws_sfn_state_machine.this.definition).States,
        jsondecode(aws_sfn_state_machine.this.definition).States.RunInjectors.ItemProcessor.States,
        ] : [
        for name, s in states : concat(
          [for n in compact([try(s.Next, ""), try(s.Default, "")]) : contains(keys(states), n)],
          [for c in try(s.Choices, []) : contains(keys(states), c.Next)],
          [for c in try(s.Catch, []) : contains(keys(states), c.Next)],
        )
      ]
    ]))
    error_message = "A Next/Default/Choice/Catch target does not exist."
  }

  assert {
    condition = alltrue([
      for c in jsondecode(aws_sfn_state_machine.this.definition).States.Validate.Choices :
      contains(keys(jsondecode(aws_sfn_state_machine.this.definition).States), c.Next) &&
      jsondecode(aws_sfn_state_machine.this.definition).States[c.Next].Next == "NotifyFailure"
    ])
    error_message = "Every rejected input must be reported through the failure notification."
  }
}
