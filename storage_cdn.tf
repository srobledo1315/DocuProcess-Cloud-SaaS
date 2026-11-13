### ==============================================================================
### 6. STORAGE & CONTENT DELIVERY (S3 FRONTEND, S3 DOCS, S3 TRAILS, CLOUDFRONT)
### ==============================================================================

# Bucket S3: Alojamiento estático del Frontend
resource "aws_s3_bucket" "frontend" {
  bucket        = "docuprocess-frontend-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = {
    Name = "${local.name_prefix}-frontend-bucket"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Origin Access Control (OAC) para acceso seguro entre CloudFront y S3
resource "aws_cloudfront_origin_access_control" "frontend_oac" {
  name                              = "${local.name_prefix}-oac"
  description                       = "OAC para restringir lectura del bucket S3 exclusivamente a CloudFront"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Distribución Global Amazon CloudFront (CDN)
resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  comment             = "Distribucion CDN para Frontend DocuProcess Cloud"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_domain_name
    origin_id                = "S3-${aws_s3_bucket.frontend.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend_oac.id
  }

  origin {
    domain_name = aws_lb.api.dns_name
    origin_id   = "ALB-${aws_lb.api.id}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Comportamiento para API REST hacia el ALB (Evita Mixed Content y CORS en el navegador)
  ordered_cache_behavior {
    path_pattern     = "/api/*"
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = "ALB-${aws_lb.api.id}"

    forwarded_values {
      query_string = true
      headers      = ["Accept", "Authorization", "Content-Type", "Origin", "Referer"]
      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
  }

  # Comportamiento para endpoint /health hacia el ALB
  ordered_cache_behavior {
    path_pattern     = "/health"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = "ALB-${aws_lb.api.id}"

    forwarded_values {
      query_string = false
      headers      = ["Accept", "Origin"]
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${aws_s3_bucket.frontend.id}"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  # Nota de integración: No se configuran custom_error_response globales 403/404 -> 200 /index.html
  # porque en CloudFront aplican también al comportamiento /api/*, enmascarando respuestas JSON
  # 403 Forbidden (RBAC) y 404 Not Found de la API REST como 200 HTML. default_root_object sirve '/'.

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = "${local.name_prefix}-cloudfront-cdn"
  }
}

# Política de Bucket S3 para autorizar únicamente a CloudFront OAC
resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipalReadOnly"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.frontend.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn
          }
        }
      }
    ]
  })
}

# Archivo index.html del Frontend SPA en el Bucket S3
resource "aws_s3_object" "frontend_index" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "index.html"
  source       = "${path.module}/frontend/index.html"
  source_hash  = filemd5("${path.module}/frontend/index.html")
  content_type = "text/html"
}

# Bucket S3: Almacenamiento persistente de documentos e imágenes procesadas
resource "aws_s3_bucket" "documents" {
  bucket        = "docuprocess-documents-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = {
    Name = "${local.name_prefix}-documents-storage"
  }
}

resource "aws_s3_bucket_versioning" "documents" {
  bucket = aws_s3_bucket.documents.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "documents" {
  bucket                  = aws_s3_bucket.documents.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CORS en S3 para permitir subida directa de archivos desde CloudFront/ALB vía Presigned URLs
resource "aws_s3_bucket_cors_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["PUT", "GET", "HEAD"]
    allowed_origins = [
      "https://${aws_cloudfront_distribution.frontend.domain_name}",
      "http://${aws_lb.api.dns_name}"
    ]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}

# Política basada en recurso para otorgar mínimo privilegio al rol EC2 (AmazonSSMRoleForInstancesQuickSetup)
# sin modificar IAM ni perder conectividad con AWS Systems Manager Session Manager.
resource "aws_s3_bucket_policy" "documents" {
  bucket = aws_s3_bucket.documents.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEC2SSMRoleBucketList"
        Effect = "Allow"
        Principal = {
          AWS = local.ec2_iam_role_arn
        }
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.documents.arn
      },
      {
        Sid    = "AllowEC2SSMRoleObjectRW"
        Effect = "Allow"
        Principal = {
          AWS = local.ec2_iam_role_arn
        }
        Action = [
          "s3:PutObject",
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.documents.arn}/*"
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.documents]
}

# Bucket S3: Registros de Auditoría para AWS CloudTrail
resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "docuprocess-cloudtrail-logs-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = {
    Name = "${local.name_prefix}-cloudtrail-logs"
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

### ==============================================================================
