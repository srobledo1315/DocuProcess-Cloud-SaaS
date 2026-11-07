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
### DATA SOURCES
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
