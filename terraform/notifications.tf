resource "aws_sns_topic" "notifications" {
  name              = "${var.name}-notifications"
  kms_master_key_id = var.kms_key_arn == null ? "alias/aws/sns" : var.kms_key_arn
  tags              = local.tags
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.notification_emails)

  topic_arn = aws_sns_topic.notifications.arn
  protocol  = "email"
  endpoint  = each.value
}
