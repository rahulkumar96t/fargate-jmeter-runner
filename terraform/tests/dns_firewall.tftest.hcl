mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  target_domains        = ["perf.example.com", "*.perf.example.com"]
  extra_allowed_domains = ["login.example.net"]
}

run "targets_are_allowed_first" {
  assert {
    condition     = toset(aws_route53_resolver_firewall_domain_list.targets.domains) == toset(["perf.example.com", "*.perf.example.com"])
    error_message = "The target allow-list must contain exactly target_domains."
  }

  assert {
    condition = (
      aws_route53_resolver_firewall_rule.allow_targets.action == "ALLOW" &&
      aws_route53_resolver_firewall_rule.allow_targets.firewall_domain_list_id == aws_route53_resolver_firewall_domain_list.targets.id
    )
    error_message = "Target domains must be allowed."
  }

  assert {
    condition     = aws_route53_resolver_firewall_rule.allow_targets.firewall_domain_redirection_action == "TRUST_REDIRECTION_DOMAIN"
    error_message = "CNAME chains of allowed targets (CDN, load balancer) must be trusted."
  }
}

run "only_the_needed_aws_endpoints_are_allowed" {
  assert {
    condition = toset(aws_route53_resolver_firewall_domain_list.aws_services.domains) == toset([
      "api.ecr.eu-central-1.amazonaws.com",
      "ecr.eu-central-1.amazonaws.com",
      "111111111111.dkr.ecr.eu-central-1.amazonaws.com",
      "s3.eu-central-1.amazonaws.com",
      "*.s3.eu-central-1.amazonaws.com",
      "logs.eu-central-1.amazonaws.com",
      "sts.eu-central-1.amazonaws.com",
      "*.eu-central-1.compute.internal",
      "*.ec2.internal",
      "login.example.net",
    ])
    error_message = "Unexpected AWS service allow-list."
  }

  assert {
    condition = alltrue([
      for d in aws_route53_resolver_firewall_domain_list.aws_services.domains :
      !contains(["*.amazonaws.com", "*.elb.amazonaws.com", "*.execute-api.eu-central-1.amazonaws.com", "*.cloudfront.net"], d)
    ])
    error_message = "Broad wildcards would let a plan reach other environments' load balancers or APIs."
  }

  assert {
    condition     = aws_route53_resolver_firewall_rule.allow_aws_services.action == "ALLOW"
    error_message = "AWS service endpoints must be allowed."
  }
}

run "everything_else_is_blocked" {
  assert {
    condition     = aws_route53_resolver_firewall_domain_list.everything.domains == toset(["*"])
    error_message = "The block rule must match every domain."
  }

  assert {
    condition = (
      aws_route53_resolver_firewall_rule.block_everything_else.action == "BLOCK" &&
      aws_route53_resolver_firewall_rule.block_everything_else.block_response == "NXDOMAIN" &&
      aws_route53_resolver_firewall_rule.block_everything_else.firewall_domain_list_id == aws_route53_resolver_firewall_domain_list.everything.id
    )
    error_message = "All other queries must be answered with NXDOMAIN."
  }

  assert {
    condition = (
      aws_route53_resolver_firewall_rule.allow_targets.priority < aws_route53_resolver_firewall_rule.block_everything_else.priority &&
      aws_route53_resolver_firewall_rule.allow_aws_services.priority < aws_route53_resolver_firewall_rule.block_everything_else.priority
    )
    error_message = "Allow rules must be evaluated before the catch-all block rule."
  }

  assert {
    condition = alltrue([
      for r in [
        aws_route53_resolver_firewall_rule.allow_targets,
        aws_route53_resolver_firewall_rule.allow_aws_services,
        aws_route53_resolver_firewall_rule.block_everything_else,
      ] : r.firewall_rule_group_id == aws_route53_resolver_firewall_rule_group.this.id
    ])
    error_message = "All rules must belong to the same rule group."
  }
}

run "rule_group_protects_the_vpc_and_fails_closed" {
  assert {
    condition = (
      aws_route53_resolver_firewall_rule_group_association.this.vpc_id == aws_vpc.this.id &&
      aws_route53_resolver_firewall_rule_group_association.this.firewall_rule_group_id == aws_route53_resolver_firewall_rule_group.this.id
    )
    error_message = "The rule group must be associated with the load-test VPC."
  }

  assert {
    condition     = aws_route53_resolver_firewall_config.this.resource_id == aws_vpc.this.id && aws_route53_resolver_firewall_config.this.firewall_fail_open == "DISABLED"
    error_message = "The firewall must fail closed."
  }

  assert {
    condition     = contains(output.allowed_domains, "perf.example.com") && !contains(output.allowed_domains, "*")
    error_message = "allowed_domains output must list the allowed names, never the catch-all."
  }
}

run "targets_outside_the_allow_list_are_rejected_by_the_state_machine" {
  assert {
    condition = [
      for c in jsondecode(aws_sfn_state_machine.this.definition).States.Validate.Choices :
      c.Not.And[1].Or if c.Next == "RejectTargetHost"
      ][0] == [
      { StringMatches = "perf.example.com", Variable = "$.targetHost" },
      { StringMatches = "*.perf.example.com", Variable = "$.targetHost" },
    ]
    error_message = "The state machine must reject a targetHost that the DNS firewall would block."
  }
}
