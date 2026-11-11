# One bucket, three prefixes:
#   plans/<name>/<plan>.jmx (+ CSV data files)  uploaded by people, never expires
#   jtl/<run-id>/injector-<n>.jtl               raw samples, expires after jtl_retention_days
#   reports/<run-id>/index.html, summary.json   dashboard + verdict, expires after report_retention_days
resource "aws_s3_bucket" "results" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket = aws_s3_bucket.results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != null
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    id     = "expire-raw-jtl"
    status = "Enabled"

    filter {
      prefix = local.jtl_prefix
    }

    expiration {
      days = var.jtl_retention_days
    }
  }

  rule {
    id     = "expire-reports"
    status = "Enabled"

    filter {
      prefix = local.reports_prefix
    }

    expiration {
      days = var.report_retention_days
    }
  }

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {
      prefix = ""
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_policy" "results" {
  bucket = aws_s3_bucket.results.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.results.arn, "${aws_s3_bucket.results.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })

  # Applying a bucket policy while the public access block is being created can fail.
  depends_on = [aws_s3_bucket_public_access_block.results]
}

resource "aws_cloudwatch_log_group" "jmeter" {
  name              = "/ecs/${var.name}-jmeter"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}
