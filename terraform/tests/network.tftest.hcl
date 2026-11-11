mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  target_domains = ["perf.example.com"]
}

run "nat_enabled_by_default" {
  assert {
    condition     = length(aws_nat_gateway.this) == 1
    error_message = "A NAT gateway must exist while nat_enabled is true."
  }

  assert {
    condition     = aws_nat_gateway.this[0].allocation_id == aws_eip.nat.id
    error_message = "The NAT gateway must use the dedicated Elastic IP."
  }

  assert {
    condition     = aws_nat_gateway.this[0].subnet_id == aws_subnet.public[0].id
    error_message = "The NAT gateway must sit in a public subnet."
  }

  assert {
    condition     = length(aws_route.private_egress) == 1 && aws_route.private_egress[0].destination_cidr_block == "0.0.0.0/0"
    error_message = "Private subnets need a default route through the NAT gateway."
  }

  assert {
    condition     = output.nat_egress_ip == "198.51.100.24"
    error_message = "nat_egress_ip must expose the Elastic IP's public address."
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.LoadDefaults.Result.fixed.egressEnabled == true
    error_message = "The state machine must know that egress is available."
  }
}

# Same state as the previous run: this is the "end of test campaign" apply.
run "nat_disabled_keeps_the_eip" {
  variables {
    nat_enabled = false
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 0
    error_message = "No NAT gateway may exist while nat_enabled is false."
  }

  assert {
    condition     = length(aws_route.private_egress) == 0
    error_message = "The default route must be removed together with the NAT gateway."
  }

  assert {
    condition     = aws_eip.nat.domain == "vpc"
    error_message = "The Elastic IP must still exist when the NAT gateway is disabled."
  }

  assert {
    condition     = output.nat_eip_allocation_id == run.nat_enabled_by_default.nat_eip_allocation_id
    error_message = "Toggling the NAT gateway must not replace the Elastic IP (the WAF allow-list depends on it)."
  }

  assert {
    condition     = output.nat_egress_ip == run.nat_enabled_by_default.nat_egress_ip
    error_message = "The egress IP must not change when the NAT gateway is disabled."
  }

  assert {
    condition     = jsondecode(aws_sfn_state_machine.this.definition).States.LoadDefaults.Result.fixed.egressEnabled == false
    error_message = "With the NAT disabled the state machine must reject runs up front."
  }
}

run "nat_re_enabled_reuses_the_eip" {
  variables {
    nat_enabled = true
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1 && aws_nat_gateway.this[0].allocation_id == run.nat_enabled_by_default.nat_eip_allocation_id
    error_message = "The re-created NAT gateway must use the original Elastic IP."
  }
}

run "two_azs_with_public_and_private_subnets" {
  assert {
    condition     = length(aws_subnet.public) == 2 && length(aws_subnet.private) == 2
    error_message = "Expected two public and two private subnets."
  }

  assert {
    condition     = jsonencode(aws_subnet.private[*].availability_zone) == jsonencode(["eu-central-1a", "eu-central-1b"])
    error_message = "Private subnets must be spread over the first two AZs in sorted order."
  }

  assert {
    condition     = aws_subnet.public[0].availability_zone != aws_subnet.public[1].availability_zone
    error_message = "Public subnets must be in different AZs."
  }

  assert {
    condition     = aws_subnet.private[0].cidr_block == "10.80.0.0/18" && aws_subnet.private[1].cidr_block == "10.80.64.0/18"
    error_message = "Private subnets must take the first two quarters of the VPC."
  }

  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.80.192.0/22" && aws_subnet.public[1].cidr_block == "10.80.196.0/22"
    error_message = "Public subnets must be carved from the last quarter of the VPC."
  }

  assert {
    condition     = alltrue([for s in concat(aws_subnet.private, aws_subnet.public) : s.map_public_ip_on_launch == false])
    error_message = "No subnet may assign public IPs on launch."
  }

  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" && contains(aws_vpc_endpoint.s3.route_table_ids, aws_route_table.private.id)
    error_message = "S3 traffic must use the gateway endpoint from the private route table."
  }
}

run "injector_egress_is_limited_to_allowed_ports" {
  variables {
    allowed_egress_ports = [443, 8443]
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_egress_rule.injector)) == toset(["443", "8443"])
    error_message = "One egress rule per allowed port expected."
  }

  assert {
    condition     = alltrue([for r in aws_vpc_security_group_egress_rule.injector : r.ip_protocol == "tcp" && r.from_port == r.to_port])
    error_message = "Egress rules must be single TCP ports."
  }
}
