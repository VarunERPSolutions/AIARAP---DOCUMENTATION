# S3 + CloudFront static hosting for react-external-app / react-support-app,
# dev environment only for now (ADR-0038 §1; qa/prod are a deliberate
# follow-up once this is validated — see parking lot #56).
#
# Deliberately no custom domain/ACM cert this pass — each distribution is
# reached via its default *.cloudfront.net domain. Per-Tenant hostname
# aliasing (ADR-0038 §4, parking lot #60) isn't designed yet, so wiring up
# Route53/ACM now would be guesswork.
#
# Replaces the old EC2/nginx dev deploy target for these two apps only —
# node-app/java-app are unaffected and keep deploying via ci.tf's ECR+SSM
# path onto their own EC2 instances.

locals {
  spa_apps = {
    react_external = {
      bucket_name = "varunerp-react-external-app-dev"
    }
    react_support = {
      bucket_name = "varunerp-react-support-app-dev"
    }
  }
}

resource "aws_s3_bucket" "spa" {
  for_each = local.spa_apps
  bucket   = each.value.bucket_name

  tags = {
    Name = each.value.bucket_name
  }
}

# No public access of any kind — the bucket is reachable only through
# CloudFront's Origin Access Control, via the bucket policy below.
resource "aws_s3_bucket_public_access_block" "spa" {
  for_each = aws_s3_bucket.spa

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning + a bounded lifecycle: a bad deploy's `s3 sync --delete` can be
# recovered from by restoring the previous object versions (see the
# rollback procedure in docs/infra/INFRASTRUCTURE_REFERENCE.md), without
# keeping every historical version forever.
resource "aws_s3_bucket_versioning" "spa" {
  for_each = aws_s3_bucket.spa

  bucket = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "spa" {
  for_each = aws_s3_bucket.spa

  bucket = each.value.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_cloudfront_origin_access_control" "spa" {
  for_each = local.spa_apps

  name                              = "${each.value.bucket_name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "spa" {
  for_each = local.spa_apps

  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  http_version        = "http2and3" # HTTP/3 doesn't require a custom domain/cert — no reason not to enable it
  is_ipv6_enabled     = true
  web_acl_id          = aws_wafv2_web_acl.spa.arn

  # Only react_support has a custom domain requested (public_apps_domain.tf);
  # react_external keeps no aliases and stays on its default domain.
  aliases = contains(keys(local.spa_custom_domains), each.key) ? [local.spa_custom_domains[each.key]] : []

  origin {
    domain_name              = aws_s3_bucket.spa[each.key].bucket_regional_domain_name
    origin_id                = each.value.bucket_name
    origin_access_control_id = aws_cloudfront_origin_access_control.spa[each.key].id
  }

  # Default behavior: index.html and any other unhashed file (favicon.svg,
  # icons.svg) — never cached beyond revalidation, so a deploy is visible
  # immediately without depending on invalidation for correctness.
  default_cache_behavior {
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = each.value.bucket_name
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    cache_policy_id            = aws_cloudfront_cache_policy.spa_default.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.spa[each.key].id
  }

  # Vite's content-hashed build output — a new deploy never reuses a
  # filename here, so a 1-year immutable cache is safe and never needs
  # invalidating.
  ordered_cache_behavior {
    path_pattern               = "/assets/*"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = each.value.bucket_name
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    cache_policy_id            = aws_cloudfront_cache_policy.spa_immutable_assets.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.spa[each.key].id
  }

  logging_config {
    bucket          = aws_s3_bucket.cf_logs.bucket_domain_name
    prefix          = "${each.key}/"
    include_cookies = false
  }

  # SPA client-side routing: any path not matching a real object in the
  # bucket comes back from S3 as 403 (private bucket, no ListBucket grant)
  # rather than 404 — mirrors the old nginx `try_files $uri /index.html`.
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

  # react_support uses the ACM cert from public_apps_domain.tf once DNS
  # validation completes; react_external has no entry in spa_custom_domains
  # and keeps the default CloudFront certificate (TLSv1 floor, unavoidable
  # without a custom domain).
  viewer_certificate {
    cloudfront_default_certificate = contains(keys(local.spa_custom_domains), each.key) ? null : true
    acm_certificate_arn            = contains(keys(local.spa_custom_domains), each.key) ? aws_acm_certificate_validation.spa[each.key].certificate_arn : null
    ssl_support_method             = contains(keys(local.spa_custom_domains), each.key) ? "sni-only" : null
    minimum_protocol_version       = contains(keys(local.spa_custom_domains), each.key) ? "TLSv1.2_2021" : null
  }

  tags = {
    Name = "${each.value.bucket_name}-cdn"
  }
}

data "aws_iam_policy_document" "spa_bucket_policy" {
  for_each = local.spa_apps

  statement {
    sid       = "AllowCloudFrontOAC"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.spa[each.key].arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.spa[each.key].arn]
    }
  }
}

resource "aws_s3_bucket_policy" "spa" {
  for_each = local.spa_apps

  bucket = aws_s3_bucket.spa[each.key].id
  policy = data.aws_iam_policy_document.spa_bucket_policy[each.key].json
}

# --- CI permissions: let github_actions_ci (ci.tf) sync builds and bust ----
# the CDN cache, without touching that role's ECR/SSM statements.

data "aws_iam_policy_document" "github_actions_spa_deploy" {
  statement {
    sid = "SpaBucketSync"
    actions = [
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = concat(
      [for b in aws_s3_bucket.spa : b.arn],
      [for b in aws_s3_bucket.spa : "${b.arn}/*"],
    )
  }

  statement {
    sid       = "SpaCacheInvalidate"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = [for d in aws_cloudfront_distribution.spa : d.arn]
  }
}

resource "aws_iam_role_policy" "github_actions_spa_deploy" {
  name   = "github-actions-spa-deploy"
  role   = aws_iam_role.github_actions_ci.id
  policy = data.aws_iam_policy_document.github_actions_spa_deploy.json
}

output "spa_bucket_names" {
  description = "S3 bucket per app — target of `aws s3 sync` in each app's CI workflow."
  value       = { for k, b in aws_s3_bucket.spa : k => b.id }
}

output "spa_distribution_ids" {
  description = "CloudFront distribution ID per app — target of `aws cloudfront create-invalidation` in each app's CI workflow."
  value       = { for k, d in aws_cloudfront_distribution.spa : k => d.id }
}

output "spa_distribution_domain_names" {
  description = "Default *.cloudfront.net hostname per app — where each app is actually reachable until a custom domain (ADR-0038 §4, parking lot #60) is designed."
  value       = { for k, d in aws_cloudfront_distribution.spa : k => d.domain_name }
}
