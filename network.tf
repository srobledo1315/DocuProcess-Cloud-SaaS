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

