### ==============================================================================
### VALORES LOCALES Y GENERACIÓN DE IDENTIFICADORES ALEATORIOS
### ==============================================================================

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

locals {
  name_prefix          = "docuprocess-${var.environment}"
  preexisting_ssm_role = var.ssm_instance_profile_name
}

### ==============================================================================
