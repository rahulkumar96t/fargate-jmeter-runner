# Route 53 Resolver DNS Firewall as a "walled garden": the VPC can resolve the target
# domains and the handful of AWS endpoints the tasks need, and nothing else. A typo in a
# test plan (or a plan copied from another environment) fails at name resolution
# instead of sending production-sized load somewhere it was never meant to go.

locals {
  # Endpoints an injector or report task talks to: image pull (ECR API, the account's
  # registry and the S3 layer bucket), plan/result transfer (S3), the awslogs driver
  # (CloudWatch Logs) and STS. The *.internal names cover the VPC's own host names,
  # which the JVM looks up at start-up.
  aws_service_domains = sort(distinct([
    "api.ecr.${local.region}.${local.dns_suffix}",
    "ecr.${local.region}.${local.dns_suffix}",
    "${local.account_id}.dkr.ecr.${local.region}.${local.dns_suffix}",
    "s3.${local.region}.${local.dns_suffix}",
    "*.s3.${local.region}.${local.dns_suffix}",
    "logs.${local.region}.${local.dns_suffix}",
    "sts.${local.region}.${local.dns_suffix}",
    "*.${local.region}.compute.internal",
    "*.ec2.internal",
  ]))

  allowed_domains = sort(distinct(concat(var.target_domains, local.aws_service_domains, var.extra_allowed_domains)))
}

resource "aws_route53_resolver_firewall_domain_list" "targets" {
  name    = "${var.name}-targets"
  domains = sort(distinct(var.target_domains))
  tags    = local.tags
}

resource "aws_route53_resolver_firewall_domain_list" "aws_services" {
  name    = "${var.name}-aws-services"
  domains = sort(distinct(concat(local.aws_service_domains, var.extra_allowed_domains)))
  tags    = local.tags
}

resource "aws_route53_resolver_firewall_domain_list" "everything" {
  name    = "${var.name}-everything"
  domains = ["*"]
  tags    = local.tags
}

resource "aws_route53_resolver_firewall_rule_group" "this" {
  name = "${var.name}-allow-list"
  tags = local.tags
}

# Targets are usually CNAMEs to a CDN or load balancer name. Trusting the redirection
# chain of an allowed name keeps those lookups working without allow-listing the
# provider's whole domain (which would also admit every other customer behind it).
resource "aws_route53_resolver_firewall_rule" "allow_targets" {
  name                               = "allow-targets"
  firewall_rule_group_id             = aws_route53_resolver_firewall_rule_group.this.id
  firewall_domain_list_id            = aws_route53_resolver_firewall_domain_list.targets.id
  priority                           = 100
  action                             = "ALLOW"
  firewall_domain_redirection_action = "TRUST_REDIRECTION_DOMAIN"
}

resource "aws_route53_resolver_firewall_rule" "allow_aws_services" {
  name                               = "allow-aws-services"
  firewall_rule_group_id             = aws_route53_resolver_firewall_rule_group.this.id
  firewall_domain_list_id            = aws_route53_resolver_firewall_domain_list.aws_services.id
  priority                           = 200
  action                             = "ALLOW"
  firewall_domain_redirection_action = "TRUST_REDIRECTION_DOMAIN"
}

resource "aws_route53_resolver_firewall_rule" "block_everything_else" {
  name                    = "block-everything-else"
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.this.id
  firewall_domain_list_id = aws_route53_resolver_firewall_domain_list.everything.id
  priority                = 300
  action                  = "BLOCK"
  block_response          = "NXDOMAIN"
}

resource "aws_route53_resolver_firewall_rule_group_association" "this" {
  name                   = "${var.name}-allow-list"
  firewall_rule_group_id = aws_route53_resolver_firewall_rule_group.this.id
  vpc_id                 = aws_vpc.this.id
  priority               = 1000
  mutation_protection    = "DISABLED"
  tags                   = local.tags
}

# Fail closed: if the firewall cannot evaluate a query, the query is blocked.
resource "aws_route53_resolver_firewall_config" "this" {
  resource_id        = aws_vpc.this.id
  firewall_fail_open = "DISABLED"
}
