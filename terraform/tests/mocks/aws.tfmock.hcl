# Shared fake values for `mock_provider "aws"` in every test file. Only attributes the
# tests assert on, or that feed string functions, need realistic values; everything
# else gets a random placeholder value from the mock provider.

mock_data "aws_availability_zones" {
  defaults = {
    names = ["eu-central-1c", "eu-central-1a", "eu-central-1b"]
  }
}

mock_data "aws_region" {
  defaults = {
    region = "eu-central-1"
  }
}

mock_data "aws_caller_identity" {
  defaults = {
    account_id = "111111111111"
  }
}

mock_data "aws_partition" {
  defaults = {
    partition  = "aws"
    dns_suffix = "amazonaws.com"
  }
}

mock_resource "aws_eip" {
  defaults = {
    id        = "eipalloc-0a1b2c3d4e5f60718"
    public_ip = "198.51.100.24"
  }
}

mock_resource "aws_ecs_cluster" {
  defaults = {
    arn = "arn:aws:ecs:eu-central-1:111111111111:cluster/jmeter"
  }
}

mock_resource "aws_ecs_task_definition" {
  defaults = {
    arn = "arn:aws:ecs:eu-central-1:111111111111:task-definition/jmeter-jmeter:7"
  }
}

mock_resource "aws_s3_bucket" {
  defaults = {
    arn = "arn:aws:s3:::jmeter-results-111111111111-eu-central-1"
  }
}

mock_resource "aws_sns_topic" {
  defaults = {
    arn = "arn:aws:sns:eu-central-1:111111111111:jmeter-notifications"
  }
}

# The provider validates ARN-typed arguments even under a mock, so resources whose ARN
# feeds another resource need a well-formed value.
mock_resource "aws_iam_role" {
  defaults = {
    arn = "arn:aws:iam::111111111111:role/jmeter-mock"
  }
}

mock_resource "aws_cloudwatch_log_group" {
  defaults = {
    arn = "arn:aws:logs:eu-central-1:111111111111:log-group:/mock"
  }
}
