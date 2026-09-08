# S3 + CloudFront + ACM for one client-rendered SPA (ADR-0008), one
# environment at a time — no server, no container, decoupled from any EC2
# instance's health. Parameterized so the same shape serves both
# react-external-app and react-support-app (ADR-0038) without duplicating
# this file twice; see shared/public_apps.tf for the two callers.
#
# CloudFront requires its ACM cert in us-east-1 regardless of where the
# distribution itself serves from — the caller's provider is already
# us-east-1 (see shared/versions.tf), so no cross-region provider alias is
# needed here, same reasoning already used for the Cognito custom domain
# cert in shared/cognito.tf.
#
# Out of scope here (ADR-0038 open items, not yet designed): the Cognito
# app client/scopes this app authenticates with, and the CI/CD pipeline that
# actually builds and uploads to these buckets — this module only stands up
# the hosting target those depend on.

locals {
  # "prd" = bare subdomain; every other environment gets a prefix — same
  # convention as modules/tenant-onboarding/certs_domain.tf's env_domain_name.
  domain_name = {
    for env in var.environments :
    env => env == "prd" ? "${var.subdomain}.${var.base_domain}" : "${env}.${var.subdomain}.${var.base_domain}"
  }
}

# Bare + wildcard SAN covers every environment's domain on one cert, same
# two-SAN shape as modules/tenant-onboarding/certs_domain.tf — a wildcard
# doesn't cover the apex, so both are requested explicitly.
resource "aws_acm_certificate" "this" {
  domain_name               = "${var.subdomain}.${var.base_domain}"
  subject_alternative_names = ["*.${var.subdomain}.${var.base_domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 300
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# One OAC per app, reused across every environment's distribution — it signs
# requests to S3 generically, it isn't bound to one bucket or distribution.
resource "aws_cloudfront_origin_access_control" "this" {
  name                              = "varunerp-${var.subdomain}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_bucket" "this" {
  for_each = toset(var.environments)
  bucket   = "varunerp-${var.subdomain}-${each.key}"
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Scoped to the matching environment's own distribution via SourceArn — not
# "any CloudFront distribution in this account" — so dev's distribution
# can't read qa's bucket even though both use the same OAC.
resource "aws_s3_bucket_policy" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontReadOnly"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${each.value.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.this[each.key].arn
        }
      }
    }]
  })
}

resource "aws_cloudfront_distribution" "this" {
  for_each = toset(var.environments)

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [local.domain_name[each.key]]
  price_class         = var.price_class
  comment             = "${var.app_name} — ${each.key}"

  origin {
    domain_name              = aws_s3_bucket.this[each.key].bucket_regional_domain_name
    origin_id                = "s3-${var.subdomain}-${each.key}"
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-${var.subdomain}-${each.key}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    # AWS managed "CachingOptimized" policy (no forwarded query strings/
    # cookies/headers, long default TTL) — a static SPA build needs none of
    # that; picking up a new build immediately is CI's job (invalidate on
    # deploy), not a cache-policy concern.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # Client-side routing (React Router et al.): a deep link or a refresh on a
  # sub-route 403s/404s at S3 (no such object) — rewrite both to /index.html
  # with a 200 so the SPA's own router takes over, instead of a raw S3 error
  # page reaching the visitor.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.this.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

resource "aws_route53_record" "alias" {
  for_each = toset(var.environments)
  zone_id  = var.route53_zone_id
  name     = local.domain_name[each.key]
  type     = "A"

  alias {
    name                   = aws_cloudfront_distribution.this[each.key].domain_name
    zone_id                = aws_cloudfront_distribution.this[each.key].hosted_zone_id
    evaluate_target_health = false
  }
}
