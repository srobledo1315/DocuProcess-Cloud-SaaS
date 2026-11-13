### ==============================================================================
### VALORES LOCALES Y GENERACIÓN DE IDENTIFICADORES ALEATORIOS
### ==============================================================================

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "random_password" "db_password" {
  length  = 16
  special = false
}

locals {
  name_prefix          = "docuprocess-${var.environment}"
  preexisting_ssm_role = var.ssm_instance_profile_name
  ec2_iam_role_arn     = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/AmazonSSMRoleForInstancesQuickSetup"
  db_password          = coalesce(var.db_password, random_password.db_password.result)
}

### ==============================================================================
