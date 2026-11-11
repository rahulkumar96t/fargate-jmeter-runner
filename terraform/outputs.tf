output "nat_egress_ip" {
  description = "The single public IPv4 address all injector traffic leaves from. Allow-list it in the target's WAF. Stable across nat_enabled toggles."
  value       = aws_eip.nat.public_ip
}

output "nat_eip_allocation_id" {
  description = "Allocation ID of the egress Elastic IP."
  value       = aws_eip.nat.id
}

output "nat_enabled" {
  description = "Whether the NAT gateway currently exists. Runs are rejected while it is false."
  value       = var.nat_enabled
}

output "vpc_id" {
  description = "ID of the load-test VPC."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Subnets the injector tasks run in."
  value       = aws_subnet.private[*].id
}

output "injector_security_group_id" {
  description = "Security group attached to every injector and report task."
  value       = aws_security_group.injector.id
}

output "allowed_domains" {
  description = "Every domain the DNS firewall lets the VPC resolve; everything else gets NXDOMAIN."
  value       = local.allowed_domains
}

output "dns_firewall_rule_group_id" {
  description = "ID of the DNS firewall rule group associated with the VPC."
  value       = aws_route53_resolver_firewall_rule_group.this.id
}

output "ecr_repository_url" {
  description = "Push the JMeter image here (tag must match image_tag)."
  value       = aws_ecr_repository.jmeter.repository_url
}

output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster the tasks run in."
  value       = aws_ecs_cluster.this.arn
}

output "task_definition_arn" {
  description = "ARN (with revision) of the jmeter task definition."
  value       = aws_ecs_task_definition.jmeter.arn
}

output "injector_sizes" {
  description = "Fargate CPU units and memory (MiB) per injector size."
  value       = var.injector_sizes
}

output "results_bucket" {
  description = "Bucket for test plans (plans/), raw results (jtl/) and reports (reports/)."
  value       = aws_s3_bucket.results.bucket
}

output "log_group_name" {
  description = "CloudWatch log group of the JMeter containers."
  value       = aws_cloudwatch_log_group.jmeter.name
}

output "state_machine_arn" {
  description = "Start a run by starting an execution of this state machine (see scripts/run-test.sh)."
  value       = aws_sfn_state_machine.this.arn
}

output "notification_topic_arn" {
  description = "SNS topic that receives the pass/fail notification of every run."
  value       = aws_sns_topic.notifications.arn
}
