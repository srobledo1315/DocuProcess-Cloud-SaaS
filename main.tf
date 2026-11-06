### ==============================================================================
### DOCUPROCESS CLOUD - INFRAESTRUCTURA COMO CÓDIGO (TERRAFORM)
### Arquitectura SaaS Desacoplada: IaaS + PaaS + CDN en AWS Academy Sandbox
### ==============================================================================

### ==============================================================================
### 1. PROVIDERS & TERRAFORM CONFIGURATION
### ==============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "DocuProcess-Cloud"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Course      = "Infraestructura-III-ICESI"
    }
  }
}

### ==============================================================================
### 2. VARIABLES & LOCALS
### ==============================================================================

variable "aws_region" {
  type        = string
  description = "Región de AWS para el despliegue de infraestructura"
  default     = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Ambiente de despliegue (dev, staging, prod)"
  default     = "prod"
}

variable "vpc_cidr" {
  type        = string
  description = "Bloque CIDR de la VPC principal"
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "CIDRs para subredes públicas (ALB y NAT Gateway)"
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "private_compute_subnet_cidrs" {
  type        = list(string)
  description = "CIDRs para subredes privadas de cómputo (EC2 API y Worker)"
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_db_subnet_cidrs" {
  type        = list(string)
  description = "CIDRs para subredes privadas de base de datos (RDS)"
  default     = ["10.0.20.0/24", "10.0.21.0/24"]
}

variable "instance_type" {
  type        = string
  description = "Tipo de instancia EC2 permitida en AWS Academy Sandbox (t2.micro o t3.micro)"
  default     = "t3.micro"
}

variable "db_instance_class" {
  type        = string
  description = "Clase de instancia para RDS Single-AZ en Sandbox"
  default     = "db.t3.micro"
}

variable "db_name" {
  type        = string
  description = "Nombre de la base de datos relacional MySQL"
  default     = "docuprocess_db"
}

variable "db_username" {
  type        = string
  description = "Usuario administrador de RDS MySQL"
  default     = "docuadmin"
}

variable "db_password" {
  type        = string
  description = "Contraseña maestra para RDS MySQL (mínimo 8 caracteres)"
  default     = "DocuProcess2026Secure!"
  sensitive   = true
}

variable "alert_email" {
  type        = string
  description = "Correo electrónico para la suscripción a alertas de procesamiento y CloudWatch"
  default     = "admin-docuprocess@icesi.edu.co"
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

locals {
  name_prefix          = "docuprocess-${var.environment}"
  preexisting_ssm_role = "AmazonSSMRoleForInstancesQuickSetup"
}

### ==============================================================================
### 3. DATA SOURCES
### ==============================================================================

# Zonas de disponibilidad activas en la región actual
data "aws_availability_zones" "available" {
  state = "available"
}

# Identificador de la cuenta de AWS actual para construcción determinista de ARNs
data "aws_caller_identity" "current" {}

# AMI oficial más reciente de Amazon Linux 2023 (incluye agente SSM preinstalado)
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

### ==============================================================================
### 4. NETWORKING (VPC, SUBNETS, GATEWAYS, ROUTE TABLES & ENDPOINTS)
### ==============================================================================

# VPC Aislada DocuProcess
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

# Internet Gateway para tráfico entrante del ALB y salida del NAT Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# Subredes Públicas (2 Zonas de Disponibilidad para Alta Disponibilidad del ALB)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-subnet-${count.index + 1}"
    Tier = "Public"
  }
}

# Subredes Privadas de Cómputo (EC2 Auto Scaling Group)
resource "aws_subnet" "private_compute" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_compute_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${local.name_prefix}-private-compute-subnet-${count.index + 1}"
    Tier = "Private-Compute"
  }
}

# Subredes Privadas de Base de Datos (RDS Subnet Group)
resource "aws_subnet" "private_db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_db_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${local.name_prefix}-private-db-subnet-${count.index + 1}"
    Tier = "Private-Database"
  }
}

# IP Elástica para NAT Gateway (1 EIP permitido dentro de las cuotas de Vocareum)
resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]

  tags = {
    Name = "${local.name_prefix}-nat-eip"
  }
}

# NAT Gateway en Subred Pública 1 para salida a Internet controlada de EC2 (yum, pip, SSM, SNS)
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${local.name_prefix}-nat-gw"
  }

  depends_on = [aws_internet_gateway.igw]
}

# Tabla de Enrutamiento Pública -> Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Tabla de Enrutamiento Privada de Cómputo -> NAT Gateway
resource "aws_route_table" "private_compute" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "${local.name_prefix}-private-compute-rt"
  }
}

resource "aws_route_table_association" "private_compute" {
  count          = 2
  subnet_id      = aws_subnet.private_compute[count.index].id
  route_table_id = aws_route_table.private_compute.id
}

# Tabla de Enrutamiento Aislada de Base de Datos (Sin salida a Internet)
resource "aws_route_table" "private_db" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-private-db-rt"
  }
}

resource "aws_route_table_association" "private_db" {
  count          = 2
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private_db.id
}

# VPC Gateway Endpoints para S3 y DynamoDB (Transferencia gratuita de datos en red interna AWS)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private_compute.id]

  tags = {
    Name = "${local.name_prefix}-s3-gateway-endpoint"
  }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private_compute.id]

  tags = {
    Name = "${local.name_prefix}-dynamodb-gateway-endpoint"
  }
}

### ==============================================================================
### 5. SECURITY GROUPS (ALB, EC2 COMPUTE, RDS DATABASE)
### ==============================================================================

# Security Group del Application Load Balancer (Acceso público web HTTP)
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Permitir trafico HTTP de usuarios hacia el ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Ingreso HTTP desde Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Egress total hacia backend en subredes privadas"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-alb-sg"
  }
}

# Security Group de Instancias EC2 (API Backend + Worker)
# Cero exposicion de puerto 22 SSH. Acceso exclusivo via Systems Manager (SSM)
resource "aws_security_group" "ec2" {
  name        = "${local.name_prefix}-ec2-compute-sg"
  description = "Aislar instancias EC2 y admitir trafico solo desde el ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Trafico HTTP entrante estrictamente desde el ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Salida general para paquetes, APIs de AWS y SSM via NAT/Endpoints"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-ec2-compute-sg"
  }
}

# Security Group de Base de Datos RDS MySQL
resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-mysql-sg"
  description = "Permitir conexion MySQL estrictamente desde las instancias EC2"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Acceso MySQL (puerto 3306) originado unicamente en EC2"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  egress {
    description = "Restriccion de salida para la base de datos"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${local.name_prefix}-rds-mysql-sg"
  }
}

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
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.frontend.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend_oac.id
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

  # SPA Routing: Redirigir errores 403 y 404 a index.html
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
### 7. DATABASES (AMAZON RDS MYSQL SINGLE-AZ & AMAZON DYNAMODB NOSQL)
### ==============================================================================

# Subnet Group para RDS distribuido en 2 subredes privadas
resource "aws_db_subnet_group" "rds" {
  name       = "${local.name_prefix}-rds-subnet-group"
  subnet_ids = aws_subnet.private_db[*].id

  tags = {
    Name = "${local.name_prefix}-rds-subnet-group"
  }
}

# Instancia RDS MySQL - Restricción Estricta Sandbox: Single-AZ (multi_az = false)
resource "aws_db_instance" "mysql" {
  identifier             = "${local.name_prefix}-mysql"
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  max_allocated_storage  = 50
  storage_type           = "gp2"
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # REGLAS INQUEBRANTABLES DE AWS ACADEMY SANDBOX
  multi_az            = false
  publicly_accessible = false
  skip_final_snapshot = true
  deletion_protection = false
  apply_immediately   = true

  tags = {
    Name = "${local.name_prefix}-rds-mysql-single-az"
  }
}

# Tabla NoSQL Amazon DynamoDB para Metadatos e Historial de Documentos
resource "aws_dynamodb_table" "metadata" {
  name         = "docuprocess-metadata"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "document_id"

  attribute {
    name = "document_id"
    type = "S"
  }

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  # Global Secondary Index para consultas optimizadas por usuario ordenadas cronológicamente
  global_secondary_index {
    name            = "UserDocumentsIndex"
    hash_key        = "user_id"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Name = "${local.name_prefix}-dynamodb-metadata"
  }
}

### ==============================================================================
### 8. NOTIFICATIONS & EVENT STREAMING (AMAZON SNS)
### ==============================================================================

# Tópico SNS para Notificaciones Operativas y Alertas de Procesamiento Documental
resource "aws_sns_topic" "alerts" {
  name = "docuprocess-alerts"

  tags = {
    Name = "${local.name_prefix}-alerts-topic"
  }
}

# Suscripción por correo electrónico a alertas
resource "aws_sns_topic_subscription" "email_alerts" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

### ==============================================================================
### 9. COMPUTE & ORCHESTRATION (ALB, LAUNCH TEMPLATE & ASG)
### ==============================================================================

# Application Load Balancer (ALB) en Subredes Públicas
resource "aws_lb" "api" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

# Target Group para las Instancias EC2 del Backend
resource "aws_lb_target_group" "api" {
  name     = "${local.name_prefix}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${local.name_prefix}-tg"
  }
}

# Listener HTTP en el ALB
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# Launch Template para el Auto Scaling Group
# Solución de Sandbox IAM: Se referencia directamente el perfil preexistente 'AmazonSSMRoleForInstancesQuickSetup'
resource "aws_launch_template" "backend" {
  name_prefix   = "${local.name_prefix}-lt-"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    name = local.preexisting_ssm_role
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.ec2.id]
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail
    exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/null) 2>&1

    echo "=== [1/5] INICIANDO PROVISIÓN DOCUPROCESS BACKEND & WORKER ==="
    dnf update -y
    dnf install -y python3-pip python3-devel gcc git

    pip3 install flask gunicorn boto3 pymysql

    # Directorio de la aplicación
    mkdir -p /opt/docuprocess
    cd /opt/docuprocess

    # Archivo de configuración de variables de entorno del sistema
    cat << 'ENVFILE' > /opt/docuprocess/.env
    AWS_DEFAULT_REGION=${var.aws_region}
    DOCUMENTS_BUCKET=${aws_s3_bucket.documents.id}
    DYNAMODB_TABLE=${aws_dynamodb_table.metadata.name}
    SNS_TOPIC_ARN=${aws_sns_topic.alerts.arn}
    DB_HOST=${aws_db_instance.mysql.address}
    DB_PORT=3306
    DB_NAME=${var.db_name}
    DB_USER=${var.db_username}
    DB_PASSWORD=${var.db_password}
    ENVFILE

    echo "=== [2/5] GENERANDO CODIGO BACKEND REST API ==="
    cat << 'PYEOF' > /opt/docuprocess/app.py
    import os
    import json
    import uuid
    import time
    from flask import Flask, request, jsonify
    import boto3
    import pymysql

    app = Flask(__name__)

    REGION = os.getenv("AWS_DEFAULT_REGION", "us-east-1")
    DOCUMENTS_BUCKET = os.getenv("DOCUMENTS_BUCKET", "")
    DYNAMODB_TABLE = os.getenv("DYNAMODB_TABLE", "docuprocess-metadata")
    SNS_TOPIC_ARN = os.getenv("SNS_TOPIC_ARN", "")
    DB_HOST = os.getenv("DB_HOST", "")
    DB_USER = os.getenv("DB_USER", "")
    DB_PASS = os.getenv("DB_PASSWORD", "")
    DB_NAME = os.getenv("DB_NAME", "")

    dynamodb = boto3.resource("dynamodb", region_name=REGION)
    table = dynamodb.Table(DYNAMODB_TABLE)
    s3_client = boto3.client("s3", region_name=REGION)
    sns_client = boto3.client("sns", region_name=REGION)

    @app.route("/health", methods=["GET"])
    def health():
        return jsonify({"status": "healthy", "service": "DocuProcess-API", "timestamp": time.time()}), 200

    @app.route("/api/v1/auth/register", methods=["POST"])
    def register():
        data = request.get_json() or {}
        username = data.get("username", "demo_user")
        email = data.get("email", "demo@icesi.edu.co")
        user_id = str(uuid.uuid4())
        
        # Persistencia en RDS MySQL
        try:
            conn = pymysql.connect(host=DB_HOST, user=DB_USER, password=DB_PASS, database=DB_NAME, connect_timeout=5)
            with conn.cursor() as cursor:
                cursor.execute("""
                    CREATE TABLE IF NOT EXISTS users (
                        id VARCHAR(64) PRIMARY KEY,
                        username VARCHAR(50) NOT NULL,
                        email VARCHAR(100) NOT NULL,
                        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                    );
                """)
                cursor.execute("INSERT INTO users (id, username, email) VALUES (%s, %s, %s);", (user_id, username, email))
            conn.commit()
            conn.close()
            return jsonify({"message": "Usuario registrado exitosamente", "user_id": user_id}), 201
        except Exception as e:
            return jsonify({"error": str(e)}), 500

    @app.route("/api/v1/documents", methods=["POST"])
    def upload_document():
        data = request.get_json() or {}
        user_id = data.get("user_id", "anonymous")
        filename = data.get("filename", "sample.pdf")
        doc_id = str(uuid.uuid4())
        created_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

        # Registrar estado inicial en DynamoDB
        table.put_item(
            Item={
                "document_id": doc_id,
                "user_id": user_id,
                "filename": filename,
                "status": "QUEUED",
                "created_at": created_at
            }
        )

        return jsonify({
            "message": "Documento encolado para procesamiento",
            "document_id": doc_id,
            "status": "QUEUED"
        }), 202

    @app.route("/api/v1/documents/<doc_id>", methods=["GET"])
    def get_document_status(doc_id):
        response = table.get_item(Key={"document_id": doc_id})
        item = response.get("Item")
        if not item:
            return jsonify({"error": "Documento no encontrado"}), 404
        return jsonify(item), 200

    if __name__ == "__main__":
        app.run(host="0.0.0.0", port=80)
    PYEOF

    echo "=== [3/5] GENERANDO CODIGO WORKER DE PROCESAMIENTO ASINCRONO ==="
    cat << 'PYEOF' > /opt/docuprocess/worker.py
    import os
    import time
    import boto3

    REGION = os.getenv("AWS_DEFAULT_REGION", "us-east-1")
    DYNAMODB_TABLE = os.getenv("DYNAMODB_TABLE", "docuprocess-metadata")
    SNS_TOPIC_ARN = os.getenv("SNS_TOPIC_ARN", "")

    dynamodb = boto3.resource("dynamodb", region_name=REGION)
    table = dynamodb.Table(DYNAMODB_TABLE)
    sns_client = boto3.client("sns", region_name=REGION)

    print("=== DOCUPROCESS ASYNC WORKER INICIADO EN INSTANCIA EC2 ===")
    while True:
        try:
            # Escanear tareas con estado QUEUED (Simulación de procesamiento asíncrono sin Lambda)
            response = table.scan(
                FilterExpression="#st = :q",
                ExpressionAttributeNames={"#st": "status"},
                ExpressionAttributeValues={":q": "QUEUED"}
            )
            items = response.get("Items", [])
            for item in items:
                doc_id = item["document_id"]
                print(f"Procesando documento asincrono ID: {doc_id}")
                time.sleep(2) # Simulación de extracción OCR y cálculo de hashes

                # Actualizar DynamoDB con metadatos procesados
                table.update_item(
                    Key={"document_id": doc_id},
                    UpdateExpression="SET #st = :p, processed_at = :pa, pages_count = :pg, ocr_status = :ocr",
                    ExpressionAttributeNames={"#st": "status"},
                    ExpressionAttributeValues={
                        ":p": "COMPLETED",
                        ":pa": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                        ":pg": 5,
                        ":ocr": "SUCCESS"
                    }
                )

                # Notificación automática via SNS
                if SNS_TOPIC_ARN:
                    sns_client.publish(
                        TopicArn=SNS_TOPIC_ARN,
                        Subject=f"[DocuProcess Cloud] Documento Procesado: {doc_id}",
                        Message=f"El documento {item.get('filename')} (ID: {doc_id}) ha sido procesado exitosamente por el Worker EC2."
                    )
                print(f"Documento {doc_id} procesado y alerta enviada.")
        except Exception as e:
            print(f"Error en bucle del Worker: {e}")
        time.sleep(5)
    PYEOF

    echo "=== [4/5] CONFIGURANDO SERVICIOS SYSTEMD ==="
    cat << 'SVCEOF' > /etc/systemd/system/docuprocess-api.service
    [Unit]
    Description=DocuProcess REST API Service
    After=network.target

    [Service]
    User=root
    WorkingDirectory=/opt/docuprocess
    EnvironmentFile=/opt/docuprocess/.env
    ExecStart=/usr/local/bin/gunicorn --bind 0.0.0.0:80 --workers 2 app:app
    Restart=always

    [Install]
    WantedBy=multi-user.target
    SVCEOF

    cat << 'SVCEOF' > /etc/systemd/system/docuprocess-worker.service
    [Unit]
    Description=DocuProcess Async Processing Worker
    After=network.target

    [Service]
    User=root
    WorkingDirectory=/opt/docuprocess
    EnvironmentFile=/opt/docuprocess/.env
    ExecStart=/usr/bin/python3 worker.py
    Restart=always

    [Install]
    WantedBy=multi-user.target
    SVCEOF

    echo "=== [5/5] INICIANDO SERVICIOS ==="
    systemctl daemon-reload
    systemctl enable --now docuprocess-api.service
    systemctl enable --now docuprocess-worker.service
    echo "=== PROVISIÓN DE SOFTWARE FINALIZADA CON ÉXITO ==="
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.name_prefix}-asg-instance"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Auto Scaling Group (min 2, max 4, desired 2) en subredes privadas
resource "aws_autoscaling_group" "backend" {
  name_prefix         = "${local.name_prefix}-asg-"
  vpc_zone_identifier = aws_subnet.private_compute[*].id
  target_group_arns   = [aws_lb_target_group.api.arn]

  min_size         = 2
  max_size         = 4
  desired_capacity = 2

  health_check_type         = "ELB"
  health_check_grace_period = 300
  force_delete              = true

  launch_template {
    id      = aws_launch_template.backend.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-asg-node"
    propagate_at_launch = true
  }
}

### ==============================================================================
### 10. MONITORING, SCALING & AUDITING (CLOUDWATCH, ASG POLICIES, CLOUDTRAIL)
### ==============================================================================

# Política de Escalado hacia arriba (Scale-Out)
resource "aws_autoscaling_policy" "scale_up" {
  name                   = "${local.name_prefix}-scale-up"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.backend.name
}

# Alarma de CPU Alta para EC2 (> 75%)
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${local.name_prefix}-ec2-cpu-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 75
  alarm_description   = "Escalar ASG si la CPU supera el 75% durante 4 minutos"
  alarm_actions       = [aws_autoscaling_policy.scale_up.arn, aws_sns_topic.alerts.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.backend.name
  }
}

# Política de Escalado hacia abajo (Scale-In)
resource "aws_autoscaling_policy" "scale_down" {
  name                   = "${local.name_prefix}-scale-down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.backend.name
}

# Alarma de CPU Baja para EC2 (< 25%)
resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "${local.name_prefix}-ec2-cpu-low"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 25
  alarm_description   = "Reducir ASG si la CPU cae por debajo del 25% durante 4 minutos"
  alarm_actions       = [aws_autoscaling_policy.scale_down.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.backend.name
  }
}

# Alarma de CPU de Base de Datos RDS MySQL (> 80%)
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${local.name_prefix}-rds-cpu-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Alerta por saturacion de computo en base de datos transaccional RDS"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.mysql.identifier
  }
}

# Alarma de Almacenamiento Libre en RDS (< 5 GB)
resource "aws_cloudwatch_metric_alarm" "rds_storage_low" {
  alarm_name          = "${local.name_prefix}-rds-storage-low"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 5000000000 # 5 GB en bytes
  alarm_description   = "Alerta de capacidad de almacenamiento en disco para RDS MySQL"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.mysql.identifier
  }
}

# Auditoría Global con AWS CloudTrail
resource "aws_cloudtrail" "main" {
  name                          = "${local.name_prefix}-cloudtrail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_logging                = true

  depends_on = [aws_s3_bucket_policy.cloudtrail]

  tags = {
    Name = "${local.name_prefix}-cloudtrail"
  }
}

### ==============================================================================
### 11. OUTPUTS
### ==============================================================================

output "frontend_cdn_domain" {
  value       = "https://${aws_cloudfront_distribution.frontend.domain_name}"
  description = "Dominio publico de CloudFront para acceder al Frontend estatico"
}

output "frontend_s3_bucket" {
  value       = aws_s3_bucket.frontend.id
  description = "Nombre del bucket S3 para desplegar la compilacion del Frontend"
}

output "backend_alb_dns" {
  value       = "http://${aws_lb.api.dns_name}"
  description = "Punto de entrada publico HTTP del Application Load Balancer para la API REST"
}

output "rds_mysql_endpoint" {
  value       = aws_db_instance.mysql.endpoint
  description = "Endpoint de conexion privada a la base de datos relacional MySQL"
}

output "dynamodb_table_name" {
  value       = aws_dynamodb_table.metadata.name
  description = "Nombre de la tabla NoSQL DynamoDB para metadatos de documentos"
}

output "documents_s3_bucket" {
  value       = aws_s3_bucket.documents.id
  description = "Bucket S3 para almacenamiento seguro de documentos de clientes"
}

output "sns_alerts_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "ARN del topico SNS para recepcion de alertas operativas"
}

output "ssm_command_connect" {
  value       = "aws ssm start-session --target <instance_id>"
  description = "Comando CLI para conexion segura por SSM Session Manager sin puerto 22 SSH"
}
