# Custom domain for react-support-app only (dev environment), per explicit
# request — react-external-app deliberately stays on its default
# *.cloudfront.net domain; this was not asked for and ADR-0038 §4's
# per-tenant hostname design (parking lot #60) still isn't settled for it.
#
# No Route53 hosted zone exists in this account (DNS for aiarap.com is
# managed externally at Hostinger) — so both the ACM DNS-validation record
# and the final CNAME must be added there manually. Terraform can create the
# certificate and request validation, but cannot complete it by itself.

locals {
  spa_custom_domains = {
    react_support = "dev.support.aiarap.com"
  }
}

resource "aws_acm_certificate" "spa" {
  for_each = local.spa_custom_domains

  domain_name       = each.value
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = each.value
  }
}

# Surfaces the exact CNAME (name/type/value) to add at Hostinger. Terraform
# will show this after `apply` on just the certificate resource — do that
# add before running `aws_acm_certificate_validation` below, which blocks
# until the record is live and ACM sees it.
output "spa_acm_validation_records" {
  description = "DNS validation record(s) to create at Hostinger for each custom-domain cert. Add these, wait for propagation, then apply again to complete validation."
  value = {
    for k, cert in aws_acm_certificate.spa : k => {
      name  = tolist(cert.domain_validation_options)[0].resource_record_name
      type  = tolist(cert.domain_validation_options)[0].resource_record_type
      value = tolist(cert.domain_validation_options)[0].resource_record_value
    }
  }
}

resource "aws_acm_certificate_validation" "spa" {
  for_each = local.spa_custom_domains

  certificate_arn         = aws_acm_certificate.spa[each.key].arn
  validation_record_fqdns = [tolist(aws_acm_certificate.spa[each.key].domain_validation_options)[0].resource_record_name]
}

# Final CNAME to add at Hostinger once the distribution below has the alias +
# cert attached: dev.support.aiarap.com -> this value.
output "spa_custom_domain_targets" {
  description = "For each custom domain, the CloudFront domain name it must CNAME to (add at Hostinger)."
  value = {
    for k, domain in local.spa_custom_domains : k => {
      custom_domain     = domain
      cloudfront_target = aws_cloudfront_distribution.spa[k].domain_name
    }
  }
}
