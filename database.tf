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
