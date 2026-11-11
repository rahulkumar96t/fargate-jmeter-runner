terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}

variable "nat_enabled" {
  description = "Set to false after a test campaign: the NAT gateway goes away, the egress IP stays."
  type        = bool
  default     = true
}

provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = {
      environment = "load-test"
    }
  }
}

module "jmeter" {
  source = "../../terraform"

  name = "acme-perf"

  # Only these names resolve inside the load-test VPC.
  target_domains = ["perf.example.com", "*.perf.example.com"]

  max_injectors      = 10
  default_thresholds = "p95>800,errors>1%"

  nat_enabled = var.nat_enabled
}

output "egress_ip" {
  description = "Give this address to whoever manages the target's WAF allow-list."
  value       = module.jmeter.nat_egress_ip
}

output "ecr_repository_url" {
  value = module.jmeter.ecr_repository_url
}

output "results_bucket" {
  value = module.jmeter.results_bucket
}

output "state_machine_arn" {
  value = module.jmeter.state_machine_arn
}
