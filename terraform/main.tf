data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  dns_suffix = data.aws_partition.current.dns_suffix

  # Two AZs, picked deterministically so a plan does not churn when AWS reorders the list.
  azs = slice(sort(data.aws_availability_zones.available.names), 0, 2)

  # Private subnets take the first two quarters of the VPC (room for many injector ENIs);
  # the small public subnets that only hold the NAT gateway live in the last quarter.
  private_subnet_cidrs = [for i in range(2) : cidrsubnet(var.vpc_cidr, 2, i)]
  public_subnet_cidrs  = [for i in range(2) : cidrsubnet(cidrsubnet(var.vpc_cidr, 2, 3), 4, i)]

  container_name = "jmeter"
  bucket_name    = "${var.name}-results-${local.account_id}-${local.region}"

  # S3 key layout. Lifecycle rules filter on key prefixes, so raw results and reports
  # must sit under different top-level prefixes to get different retention.
  plans_prefix   = "plans/"
  jtl_prefix     = "jtl/"
  reports_prefix = "reports/"

  tags = merge({ "component" = "fargate-jmeter-runner" }, var.tags)
}
