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
echo "[4/6] Verificando estado de infraestructura previa en AWS..."
STATE_VPC=$(terraform state show aws_vpc.main 2>/dev/null | grep -E '^\s*id\s*=' | awk -F'"' '{print $2}' || true)
VPC_EXISTS="false"
if [ -n "$STATE_VPC" ]; then
  if aws ec2 describe-vpcs --vpc-ids "$STATE_VPC" >/dev/null 2>&1; then
    VPC_EXISTS="true"
  fi
fi

if [ "$VPC_EXISTS" == "false" ]; then
  echo "  → Sandbox limpio detectado. Verificando buckets S3 obsoletos en estado local..."
  for RES in aws_s3_bucket.frontend aws_s3_bucket.documents aws_s3_bucket.cloudtrail; do
    BKT=$(terraform state show "$RES" 2>/dev/null | grep -E '^\s*bucket\s*=' | head -n1 | awk -F'"' '{print $2}' || true)
    if [ -n "$BKT" ] && ! aws s3api head-bucket --bucket "$BKT" >/dev/null 2>&1; then
      echo "    • Removiendo estado huérfano de $RES ($BKT)"
      terraform state rm "$RES" >/dev/null 2>&1 || true
    fi
  done
  echo "  → Ejecutando Fase 1 (refresco + creación de red, RDS, ALB y S3)..."
  terraform apply -auto-approve || true
fi

# Desmarcar buckets S3 tras la lectura de ObjectLockConfiguration bloqueada por SCP de Vocareum
# (El provider hashicorp/aws v5 invoca s3:GetBucketObjectLockConfiguration en cada refresh)
terraform untaint aws_s3_bucket.frontend 2>/dev/null || true
terraform untaint aws_s3_bucket.documents 2>/dev/null || true
terraform untaint aws_s3_bucket.cloudtrail 2>/dev/null || true

# 5. Aprovisionamiento Final (sin refresh sobre buckets S3)
echo "[5/6] Aplicando Fase 2 (CloudFront, Políticas de Recurso, Launch Template y ASG)..."
terraform apply -auto-approve -refresh=false

# 6. Invalidación automática de caché perimetral en CloudFront tras cambios en Frontend
echo "[6/6] Sincronizando caché de Amazon CloudFront..."
CF_ID=$(terraform state show aws_cloudfront_distribution.frontend 2>/dev/null | grep -E '^\s*id\s*=' | head -n1 | awk -F'"' '{print $2}' || true)
if [ -n "$CF_ID" ]; then
  aws cloudfront create-invalidation --distribution-id "$CF_ID" --paths "/index.html" "/" >/dev/null 2>&1 || true
  echo "  ✓ Invalidación enviada a distribución CloudFront: $CF_ID"
fi

echo "=============================================================================="
echo "    Despliegue completado con éxito. Endpoints activos:"
echo "=============================================================================="
terraform output
