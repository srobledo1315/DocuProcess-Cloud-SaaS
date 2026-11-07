### ==============================================================================
### VALORES LOCALES Y GENERACIÓN DE IDENTIFICADORES ALEATORIOS
### ==============================================================================

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

locals {
  name_prefix          = "docuprocess-${var.environment}"
  preexisting_ssm_role = "c223221a5637310l18222431t1w637423204827-SsmRoleInstanceProfile-PKmlvGEgrnV4"
}

### ==============================================================================
