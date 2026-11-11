mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  target_domains = ["perf.example.com"]
}

run "rejects_more_than_40_injectors" {
  command = plan

  variables {
    max_injectors = 41
  }

  expect_failures = [var.max_injectors]
}

run "rejects_fractional_injector_limit" {
  command = plan

  variables {
    max_injectors = 2.5
  }

  expect_failures = [var.max_injectors]
}

run "rejects_unknown_default_size" {
  command = plan

  variables {
    default_injector_size = "XXL"
  }

  expect_failures = [var.default_injector_size]
}

run "rejects_invalid_fargate_combination" {
  command = plan

  variables {
    injector_sizes = {
      S  = { cpu = 1024, memory = 1024 }
      M  = { cpu = 2048, memory = 8192 }
      L  = { cpu = 4096, memory = 16384 }
      XL = { cpu = 8192, memory = 18432 }
    }
  }

  expect_failures = [var.injector_sizes]
}

run "rejects_missing_size" {
  command = plan

  variables {
    injector_sizes = {
      S = { cpu = 1024, memory = 4096 }
      M = { cpu = 2048, memory = 8192 }
      L = { cpu = 4096, memory = 16384 }
    }
  }

  expect_failures = [var.injector_sizes]
}

run "rejects_catch_all_target_domain" {
  command = plan

  variables {
    target_domains = ["*"]
  }

  expect_failures = [var.target_domains]
}

run "rejects_top_level_domain_wildcard" {
  command = plan

  variables {
    target_domains = ["*.com"]
  }

  expect_failures = [var.target_domains]
}

run "rejects_empty_target_list" {
  command = plan

  variables {
    target_domains = []
  }

  expect_failures = [var.target_domains]
}

run "rejects_reports_expiring_before_raw_results" {
  command = plan

  variables {
    jtl_retention_days    = 30
    report_retention_days = 7
  }

  expect_failures = [var.report_retention_days]
}

run "rejects_zero_day_jtl_retention" {
  command = plan

  variables {
    jtl_retention_days = 0
  }

  expect_failures = [var.jtl_retention_days]
}

run "rejects_vpc_that_is_too_small" {
  command = plan

  variables {
    vpc_cidr = "10.0.0.0/24"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_malformed_default_thresholds" {
  command = plan

  variables {
    default_thresholds = "p95 above 800"
  }

  expect_failures = [var.default_thresholds]
}

run "rejects_unknown_architecture" {
  command = plan

  variables {
    cpu_architecture = "ARM"
  }

  expect_failures = [var.cpu_architecture]
}

run "accepts_a_valid_configuration" {
  command = plan

  variables {
    target_domains     = ["perf.example.com", "*.perf.example.com"]
    max_injectors      = 40
    default_thresholds = "p95>800, errors>1%"
    cpu_architecture   = "ARM64"
  }

  assert {
    condition     = var.max_injectors == 40
    error_message = "40 injectors must be accepted."
  }
}
