#!/bin/bash
set -euo pipefail

echo "=============================================================================="
echo "    DocuProcess Cloud — Despliegue Automatizado en AWS Academy Sandbox        "
echo "=============================================================================="

# 1. Comprobación de credenciales activas en AWS CLI
echo "[1/5] Verificando credenciales activas de AWS..."
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
  exit 1
fi

ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | grep -o '"Account": "[^"]*' | cut -d'"' -f4 || echo "Desconocida")
USER_ARN=$(echo "$CALLER_IDENTITY" | grep -o '"Arn": "[^"]*' | cut -d'"' -f4 || echo "Desconocido")
echo "  ✓ Sesión activa en cuenta AWS: $ACCOUNT_ID"
echo "  ✓ Identidad IAM: $USER_ARN"

# 2. Autodetección del Instance Profile de SSM de Vocareum
echo "[2/5] Detectando Instance Profile de Systems Manager en el Sandbox..."
DETECTED_PROFILE=$(aws iam list-instance-profiles \
  --query "InstanceProfiles[?contains(InstanceProfileName, 'SsmRoleInstanceProfile')].InstanceProfileName | [0]" \
  --output text 2>/dev/null || true)

if [ -z "$DETECTED_PROFILE" ] || [ "$DETECTED_PROFILE" == "None" ]; then
  DETECTED_PROFILE="AmazonSSMRoleForInstancesQuickSetup"
fi

echo "  ✓ Instance Profile dinámico detectado: $DETECTED_PROFILE"
export TF_VAR_ssm_instance_profile_name="$DETECTED_PROFILE"

# 3. Inicialización y Validación de Terraform
echo "[3/5] Validando sintaxis y consistencia de Terraform..."
terraform init -input=false > /dev/null
terraform validate

# 4. Detección de Sandbox Limpio (recursos eliminados por fin de sesión previa)
echo "[4/5] Verificando estado de infraestructura previa en AWS..."
STATE_VPC=$(terraform state show aws_vpc.main 2>/dev/null | grep -E '^\s*id\s*=' | awk -F'"' '{print $2}' || true)
VPC_EXISTS="false"
if [ -n "$STATE_VPC" ]; then
  if aws ec2 describe-vpcs --vpc-ids "$STATE_VPC" >/dev/null 2>&1; then
    VPC_EXISTS="true"
  fi
fi

if [ "$VPC_EXISTS" == "false" ]; then
  echo "  → Sandbox limpio detectado. Ejecutando Fase 1 (refresco + creación de red, RDS, ALB y S3)..."
  terraform apply -auto-approve || true
fi

# Desmarcar buckets S3 tras la lectura de ObjectLockConfiguration bloqueada por SCP de Vocareum
terraform untaint aws_s3_bucket.frontend 2>/dev/null || true
terraform untaint aws_s3_bucket.documents 2>/dev/null || true
terraform untaint aws_s3_bucket.cloudtrail 2>/dev/null || true

# 5. Aprovisionamiento Final (sin refresh sobre buckets S3)
echo "[5/5] Aplicando Fase 2 (CloudFront, Launch Template, Auto Scaling Group y políticas)..."
terraform apply -auto-approve -refresh=false

echo "=============================================================================="
echo "    Despliegue completado con éxito. Endpoints activos:"
echo "=============================================================================="
terraform output
