### ==============================================================================
### VARIABLES DE CONFIGURACIÓN - DOCUPROCESS CLOUD
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
  description = "Contraseña maestra para RDS MySQL (si es null, se autogenera criptográficamente con random_password)"
  default     = null
  sensitive   = true
}

variable "alert_email" {
  type        = string
  description = "Correo electrónico para la suscripción a alertas de procesamiento y CloudWatch"
  default     = "azgomez2015@gmail.com"
}

variable "ssm_instance_profile_name" {
  type        = string
  description = "Nombre exacto del Instance Profile de SSM preexistente en AWS Academy Sandbox (autodetectable dinámicamente)"
  default     = "AmazonSSMRoleForInstancesQuickSetup"
}


