# WAFv2 WebACL for both SPA CloudFront distributions. One shared ACL (not
# one per app) — both apps need the identical baseline and there's no
# per-app rule difference that would justify two, per the "don't
# over-engineer" instruction for this phase.
#
# Must be created with the provider's region as us-east-1 for
# scope = "CLOUDFRONT" (a WAFv2 API requirement) — already true here
# (versions.tf pins provider "aws" to us-east-1).

resource "aws_wafv2_web_acl" "spa" {
  name        = "spa-baseline"
  description = "Baseline managed-rule protection for react-external-app/react-support-app CloudFront distributions."
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "spa-common-rule-set"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "spa-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # Adversarial testing after the initial apply showed CommonRuleSet +
  # KnownBadInputsRuleSet do not reliably catch SQL-injection-shaped query
  # strings (confirmed via `aws wafv2 get-sampled-requests` — a test
  # request like `?id=1' OR '1'='1` came back ALLOW). SQLi detection is a
  # distinct managed rule group, added here rather than assumed included.
  rule {
    name     = "AWS-AWSManagedRulesSQLiRuleSet"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesSQLiRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "spa-sqli"
      sampled_requests_enabled   = true
    }
  }

  # Reputation-based, not signature-based — blocks known-malicious source
  # IPs. Deliberately not also adding AWSManagedRulesAnonymousIpList: it
  # blocks VPNs/proxies/Tor broadly, which has a real false-positive rate
  # for a portal with an unknown-shape user base (Payers/Vendors could
  # plausibly be behind corporate VPNs) — skipping it avoids that risk for
  # this phase rather than guessing at an exception list.
  rule {
    name     = "AWS-AWSManagedRulesAmazonIpReputationList"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "spa-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "spa-baseline"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "spa-baseline"
  }
}

# WAF logs need a destination whose name AWS requires to start with
# "aws-waf-logs-" for the CloudWatch Logs destination type.
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-varunerp-spa"
  retention_in_days = 30
}

resource "aws_wafv2_web_acl_logging_configuration" "spa" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.spa.arn
}
