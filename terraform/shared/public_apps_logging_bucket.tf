# CloudFront standard access logging destination — one shared bucket, one
# prefix per app (react_external/, react_support/), rather than a bucket
# per distribution: these are low-volume dev logs, and a shared bucket with
# prefixes is simpler to operate without losing per-app separation.
#
# CloudFront's classic logging delivery writes via the predefined S3 "Log
# Delivery" group, which requires the destination bucket to have ACLs
# enabled (Block Public Access's public-facing flags do NOT treat this
# grant as public — it's a documented AWS exception).

resource "aws_s3_bucket" "cf_logs" {
  bucket = "varunerp-cloudfront-logs"

  tags = {
    Name = "varunerp-cloudfront-logs"
  }
}

resource "aws_s3_bucket_public_access_block" "cf_logs" {
  bucket                  = aws_s3_bucket.cf_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "cf_logs" {
  bucket = aws_s3_bucket.cf_logs.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "cf_logs" {
  depends_on = [aws_s3_bucket_ownership_controls.cf_logs]

  bucket = aws_s3_bucket.cf_logs.id
  acl    = "log-delivery-write"
}

resource "aws_s3_bucket_lifecycle_configuration" "cf_logs" {
  bucket = aws_s3_bucket.cf_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }
  }
}
