output "bucket_names" {
  description = "S3 bucket name per environment — CI uploads the SPA build here."
  value       = { for env, b in aws_s3_bucket.this : env => b.bucket }
}

output "distribution_ids" {
  description = "CloudFront distribution ID per environment — CI invalidates this after an S3 upload so the new build serves immediately instead of waiting out the cache TTL."
  value       = { for env, d in aws_cloudfront_distribution.this : env => d.id }
}

output "domain_names" {
  description = "Public hostname per environment (e.g. dev.portal.aiarap.com, portal.aiarap.com for prd)."
  value       = local.domain_name
}
