# Minimal, useful CloudWatch alarm baseline for the two SPA distributions —
# 4xx/5xx error-rate only, not "dozens of alarms". CloudFront's request
# metrics (namespace AWS/CloudFront) are published to us-east-1 regardless
# of distribution scope, which matches this provider's region already.
#
# No alarm_actions/ok_actions: no SNS topic (or other notification
# destination) exists in this account for this purpose, and none is
# invented here per instruction — these alarms are visible in the
# CloudWatch console/API only until a real destination is wired up.

resource "aws_cloudwatch_metric_alarm" "spa_5xx" {
  for_each = aws_cloudfront_distribution.spa

  alarm_name          = "${each.value.tags["Name"]}-5xx-error-rate"
  alarm_description   = "CloudFront 5xxErrorRate > 5% for 10 minutes — origin (S3/OAC) or CloudFront-side failures. No notification destination configured — console/API visibility only."
  namespace           = "AWS/CloudFront"
  metric_name         = "5xxErrorRate"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DistributionId = each.value.id
    Region         = "Global"
  }
}

resource "aws_cloudwatch_metric_alarm" "spa_4xx" {
  for_each = aws_cloudfront_distribution.spa

  alarm_name          = "${each.value.tags["Name"]}-4xx-error-rate"
  alarm_description   = "CloudFront 4xxErrorRate > 20% for 10 minutes. Threshold is generous because a healthy SPA still sees some 403->200 SPA-fallback conversions internally (those don't count here) and WAF blocks would also surface as 403 — this catches a genuine spike, not routine noise. No notification destination configured — console/API visibility only."
  namespace           = "AWS/CloudFront"
  metric_name         = "4xxErrorRate"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 20
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DistributionId = each.value.id
    Region         = "Global"
  }
}
