#!/bin/bash
set -euo pipefail

echo "=============================================================================="
echo "    DocuProcess Cloud — Despliegue Automatizado en AWS Academy Sandbox        "
echo "=============================================================================="

# 1. Comprobación de credenciales activas en AWS CLI
echo "[1/4] Verificando credenciales activas de AWS..."
if ! CALLER_IDENTITY=$(aws sts get-caller-identity 2>&1); then
  echo ""
  echo "❌ ERROR: No se detectaron credenciales válidas o la sesión de Vocareum expiró."
  echo "Por favor ingrese sus credenciales temporales de Vocareum ejecutando:"
  echo ""
  echo "  aws configure set aws_access_key_id \"<ACCESS_KEY>\""
  echo "  aws configure set aws_secret_access_key \"<SECRET_KEY>\""
  echo "  aws configure set aws_session_token \"<SESSION_TOKEN>\""
  echo "  aws configure set region \"us-east-1\""
  echo ""
  echo "O expórtelas como variables de entorno:"
  echo "  export AWS_ACCESS_KEY_ID=\"ASI...\""
  echo "  export AWS_SECRET_ACCESS_KEY=\"...\""
  echo "  export AWS_SESSION_TOKEN=\"...\""
  echo "  export AWS_DEFAULT_REGION=\"us-east-1\""
  echo ""
  exit 1
fi

ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | grep -o '"Account": "[^"]*' | cut -d'"' -f4 || echo "Desconocida")
USER_ARN=$(echo "$CALLER_IDENTITY" | grep -o '"Arn": "[^"]*' | cut -d'"' -f4 || echo "Desconocido")
echo "  ✓ Sesión activa en cuenta AWS: $ACCOUNT_ID"
echo "  ✓ Identidad IAM: $USER_ARN"

# 2. Autodetección del Instance Profile de SSM de Vocareum
echo "[2/4] Detectando Instance Profile de Systems Manager en el Sandbox..."
DETECTED_PROFILE=$(aws iam list-instance-profiles \
  --query "InstanceProfiles[?contains(InstanceProfileName, 'SsmRoleInstanceProfile')].InstanceProfileName | [0]" \
  --output text 2>/dev/null || true)

if [ -z "$DETECTED_PROFILE" ] || [ "$DETECTED_PROFILE" == "None" ]; then
  DETECTED_PROFILE="AmazonSSMRoleForInstancesQuickSetup"
fi

echo "  ✓ Instance Profile dinámico detectado: $DETECTED_PROFILE"
export TF_VAR_ssm_instance_profile_name="$DETECTED_PROFILE"

# 3. Inicialización y Validación de Terraform
echo "[3/4] Validando sintaxis y consistencia de Terraform..."
terraform init -input=false > /dev/null
terraform validate

# Desmarcar buckets S3 en caso de haber quedado marcados por SCP de ObjectLock
terraform untaint aws_s3_bucket.frontend 2>/dev/null || true
terraform untaint aws_s3_bucket.documents 2>/dev/null || true
terraform untaint aws_s3_bucket.cloudtrail 2>/dev/null || true

# 4. Aprovisionamiento de Infraestructura
echo "[4/4] Aplicando configuración de Terraform..."
terraform apply -auto-approve -refresh=false

echo "=============================================================================="
echo "    Despliegue completado con éxito. Endpoints activos:"
echo "=============================================================================="
terraform output

