### ==============================================================================
### 5. SECURITY GROUPS (ALB, EC2 COMPUTE, RDS DATABASE)
### ==============================================================================

# Security Group del Application Load Balancer (Acceso público web HTTP)
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Permitir trafico HTTP de usuarios hacia el ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Ingreso HTTP desde Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Egress total hacia backend en subredes privadas"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-alb-sg"
  }
}

# Security Group de Instancias EC2 (API Backend + Worker)
# Cero exposicion de puerto 22 SSH. Acceso exclusivo via Systems Manager (SSM)
resource "aws_security_group" "ec2" {
  name        = "${local.name_prefix}-ec2-compute-sg"
  description = "Aislar instancias EC2 y admitir trafico solo desde el ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Trafico HTTP entrante estrictamente desde el ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Salida general para paquetes, APIs de AWS y SSM via NAT/Endpoints"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-ec2-compute-sg"
  }
}

# Security Group de Base de Datos RDS MySQL
resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-mysql-sg"
  description = "Permitir conexion MySQL estrictamente desde las instancias EC2"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Acceso MySQL (puerto 3306) originado unicamente en EC2"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  egress {
    description = "Restriccion de salida para la base de datos"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${local.name_prefix}-rds-mysql-sg"
  }
}


### ==============================================================================
### 9. COMPUTE & ORCHESTRATION (ALB, LAUNCH TEMPLATE & ASG)
### ==============================================================================

# Application Load Balancer (ALB) en Subredes Públicas
resource "aws_lb" "api" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

# Target Group para las Instancias EC2 del Backend
resource "aws_lb_target_group" "api" {
  name     = "${local.name_prefix}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${local.name_prefix}-tg"
  }
}

# Listener HTTP en el ALB
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# Launch Template para el Auto Scaling Group
# Solución de Sandbox IAM: Se referencia directamente el perfil preexistente 'AmazonSSMRoleForInstancesQuickSetup'
resource "aws_launch_template" "backend" {
  name_prefix   = "${local.name_prefix}-lt-"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    name = local.preexisting_ssm_role
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 20
      volume_type           = "gp2"
      delete_on_termination = true
      encrypted             = true
    }
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.ec2.id]
  }

  user_data = base64gzip(<<-EOF
#!/bin/bash
    set -euo pipefail
    exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/null) 2>&1

    echo "=== [1/6] INICIANDO PROVISIÓN DOCUPROCESS BACKEND & WORKER ==="
    dnf update -y
    dnf install -y python3-pip python3-devel gcc

    pip3 install flask gunicorn boto3 pymysql flask-cors

    # Usuario de sistema sin privilegios (Principio de Mínimo Privilegio)
    id -u docuprocess >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin docuprocess

    # Directorio de la aplicación
    mkdir -p /opt/docuprocess
    cd /opt/docuprocess

    # Archivo de configuración de variables de entorno del sistema
    cat << 'ENVFILE' | sed 's/^    //' > /opt/docuprocess/.env
    AWS_DEFAULT_REGION=${var.aws_region}
    DOCUMENTS_BUCKET=${aws_s3_bucket.documents.id}
    DYNAMODB_TABLE=${aws_dynamodb_table.metadata.name}
    SNS_TOPIC_ARN=${aws_sns_topic.alerts.arn}
    DB_HOST=${aws_db_instance.mysql.address}
    DB_PORT=3306
    DB_NAME=${var.db_name}
    DB_USER=${var.db_username}
    DB_PASSWORD=${local.db_password}
    ALERT_EMAIL=${var.alert_email}
    ALB_DNS=${aws_lb.api.dns_name}
    CLOUDFRONT_DOMAIN=${aws_cloudfront_distribution.frontend.domain_name}
    RDS_ENDPOINT=${aws_db_instance.mysql.endpoint}
    PYTHONUNBUFFERED=1
ENVFILE

    echo "=== [2/6] GENERANDO CODIGO BACKEND REST API ==="
    cat << 'PYEOF' | sed 's/^    //' > /opt/docuprocess/app.py
    import os
    import re
    import json
    import uuid
    import time
    import base64
    import secrets
    import urllib.request
    from functools import wraps
    from flask import Flask, request, jsonify, g
    from flask_cors import CORS
    from werkzeug.security import generate_password_hash, check_password_hash
    import boto3
    from botocore.config import Config
    from botocore.exceptions import ClientError
    import pymysql

    app = Flask(__name__)
    CORS(app)

    REGION = os.getenv("AWS_DEFAULT_REGION", "us-east-1")
    DOCUMENTS_BUCKET = os.getenv("DOCUMENTS_BUCKET", "")
    DYNAMODB_TABLE = os.getenv("DYNAMODB_TABLE", "docuprocess-metadata")
    SNS_TOPIC_ARN = os.getenv("SNS_TOPIC_ARN", "")
    DB_HOST = os.getenv("DB_HOST", "")
    DB_USER = os.getenv("DB_USER", "")
    DB_PASS = os.getenv("DB_PASSWORD", "")
    DB_NAME = os.getenv("DB_NAME", "")
    ALERT_EMAIL = os.getenv("ALERT_EMAIL", "azgomez2015@gmail.com")
    ALB_DNS = os.getenv("ALB_DNS", "")
    CLOUDFRONT_DOMAIN = os.getenv("CLOUDFRONT_DOMAIN", "")
    RDS_ENDPOINT = os.getenv("RDS_ENDPOINT", "")

    ALLOWED_EXTENSIONS = {".pdf", ".doc", ".docx", ".png", ".jpg", ".jpeg", ".txt"}
    MAX_FILE_BYTES = 10 * 1024 * 1024  # 10 MB

    def get_instance_id():
        try:
            req = urllib.request.Request(
                "http://169.254.169.254/latest/api/token",
                method="PUT",
                headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"}
            )
            token = urllib.request.urlopen(req, timeout=1).read().decode()
            req2 = urllib.request.Request(
                "http://169.254.169.254/latest/meta-data/instance-id",
                headers={"X-aws-ec2-metadata-token": token}
            )
            return urllib.request.urlopen(req2, timeout=1).read().decode()
        except Exception:
            return os.uname().nodename

    INSTANCE_ID = get_instance_id()

    def get_db():
        return pymysql.connect(
            host=DB_HOST,
            user=DB_USER,
            password=DB_PASS,
            database=DB_NAME,
            cursorclass=pymysql.cursors.DictCursor,
            connect_timeout=5
        )

    def init_db():
        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute("""
                    CREATE TABLE IF NOT EXISTS users (
                        id VARCHAR(64) PRIMARY KEY,
                        username VARCHAR(50) NOT NULL UNIQUE,
                        email VARCHAR(100) NOT NULL,
                        password_hash VARCHAR(255) NOT NULL,
                        role VARCHAR(30) DEFAULT 'user',
                        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                    );
                """)
                cursor.execute("""
                    CREATE TABLE IF NOT EXISTS sessions (
                        token VARCHAR(128) PRIMARY KEY,
                        user_id VARCHAR(64) NOT NULL,
                        expires_at DATETIME NOT NULL,
                        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
                    );
                """)
                cursor.execute("""
                    CREATE TABLE IF NOT EXISTS documents (
                        id VARCHAR(64) PRIMARY KEY,
                        user_id VARCHAR(64) NOT NULL,
                        filename VARCHAR(255) NOT NULL,
                        status VARCHAR(30) NOT NULL,
                        s3_key VARCHAR(255),
                        processing_type VARCHAR(50) DEFAULT 'OCR_FULL',
                        priority VARCHAR(20) DEFAULT 'NORMAL',
                        file_size_kb INT DEFAULT 0,
                        pages_count INT DEFAULT 0,
                        ocr_status VARCHAR(50) DEFAULT 'PENDING',
                        sha256_hash VARCHAR(64) DEFAULT '',
                        metadata_summary TEXT,
                        error_message TEXT,
                        worker_instance VARCHAR(64) DEFAULT '',
                        notification_sent TINYINT(1) DEFAULT 0,
                        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
                    );
                """)
            conn.commit()
            conn.close()
            print("[DB] Tablas MySQL inicializadas correctamente.")
        except Exception as e:
            print(f"[DB Init Error] {e}")

    init_db()

    s3_config = Config(signature_version="s3v4", s3={"addressing_style": "virtual"})
    s3_client = boto3.client(
        "s3",
        region_name=REGION,
        endpoint_url=f"https://s3.{REGION}.amazonaws.com",
        config=s3_config
    )
    dynamodb = boto3.resource("dynamodb", region_name=REGION)
    dynamodb_table = dynamodb.Table(DYNAMODB_TABLE)
    sns_client = boto3.client("sns", region_name=REGION)

    def sanitize_filename(name):
        base = os.path.basename(name or "").strip()
        cleaned = re.sub(r"[^A-Za-z0-9._-]", "_", base)
        return cleaned[:120]

    def get_token_user(token):
        if not token:
            return None
        conn = get_db()
        try:
            with conn.cursor() as cursor:
                cursor.execute("""
                    SELECT u.id, u.username, u.email, u.role
                    FROM sessions s
                    JOIN users u ON s.user_id = u.id
                    WHERE s.token = %s AND s.expires_at > UTC_TIMESTAMP();
                """, (token,))
                return cursor.fetchone()
        finally:
            conn.close()

    def require_auth(roles=None):
        def decorator(fn):
            @wraps(fn)
            def wrapper(*args, **kwargs):
                auth_header = request.headers.get("Authorization", "")
                if not auth_header.startswith("Bearer "):
                    return jsonify({"error": "Autenticación requerida (Bearer token faltante)"}), 401
                token = auth_header.split(" ", 1)[1].strip()
                user = get_token_user(token)
                if not user:
                    return jsonify({"error": "Sesión inválida o expirada"}), 401
                if roles and user["role"] not in roles:
                    return jsonify({"error": f"Permisos insuficientes. Se requiere rol: {', '.join(roles)}"}), 403
                g.current_user = user
                g.auth_token = token
                return fn(*args, **kwargs)
            return wrapper
        return decorator

    @app.route("/", methods=["GET"])
    def root():
        return jsonify({
            "service": "DocuProcess Cloud - Backend API",
            "version": "2.1.0",
            "status": "online",
            "instance_id": INSTANCE_ID,
            "endpoints": {
                "health": "/health",
                "config": "/api/v1/config",
                "register": "/api/v1/auth/register",
                "login": "/api/v1/auth/login",
                "me": "/api/v1/auth/me",
                "presign": "/api/v1/documents/presign",
                "documents": "/api/v1/documents",
                "users": "/api/v1/users"
            },
            "frontend_portal": f"https://{CLOUDFRONT_DOMAIN}"
        }), 200

    @app.route("/health", methods=["GET"])
    def health():
        db_status = "connected"
        http_code = 200
        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute("SELECT 1;")
            conn.close()
        except Exception as e:
            db_status = f"error: {str(e)}"
            http_code = 500

        return jsonify({
            "status": "healthy" if http_code == 200 else "degraded",
            "service": "DocuProcess-API",
            "version": "2.1.0",
            "instance_id": INSTANCE_ID,
            "timestamp": time.time(),
            "rds_mysql": db_status,
            "dynamodb_table": DYNAMODB_TABLE,
            "documents_bucket": DOCUMENTS_BUCKET
        }), http_code

    @app.route("/api/v1/config", methods=["GET"])
    def public_config():
        return jsonify({
            "aws_region": REGION,
            "alb_url": f"http://{ALB_DNS}" if ALB_DNS else "",
            "cloudfront_url": f"https://{CLOUDFRONT_DOMAIN}" if CLOUDFRONT_DOMAIN else "",
            "rds_endpoint": RDS_ENDPOINT,
            "dynamodb_table": DYNAMODB_TABLE,
            "documents_bucket": DOCUMENTS_BUCKET,
            "sns_topic_arn": SNS_TOPIC_ARN,
            "alert_email": ALERT_EMAIL
        }), 200

    @app.route("/api/v1/auth/register", methods=["POST"])
    def register():
        data = request.get_json() or {}
        username = (data.get("username") or "").strip()
        email = (data.get("email") or "").strip()
        password = data.get("password") or ""
        requested_role = (data.get("role") or "user").strip().lower()

        if not re.match(r"^[A-Za-z0-9_.-]{3,50}$", username):
            return jsonify({"error": "Nombre de usuario inválido (3-50 caracteres alfanuméricos)"}), 400
        if "@" not in email or len(email) > 100:
            return jsonify({"error": "Correo electrónico inválido"}), 400
        if len(password) < 6:
            return jsonify({"error": "La contraseña debe tener al menos 6 caracteres"}), 400
        if requested_role not in ("admin", "analyst", "user"):
            return jsonify({"error": "Rol inválido (permitidos: admin, analyst, user)"}), 400

        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute("SELECT id FROM users WHERE username = %s;", (username,))
                if cursor.fetchone():
                    conn.close()
                    return jsonify({"error": f"El usuario '{username}' ya existe"}), 409

                cursor.execute("SELECT COUNT(*) AS total_admins FROM users WHERE role = 'admin';")
                admin_count = cursor.fetchone()["total_admins"]

                # Permitir rol privilegiado únicamente si es el primer admin (bootstrap) o si quien crea es admin autenticado
                final_role = "user"
                if requested_role != "user":
                    auth_header = request.headers.get("Authorization", "")
                    caller = get_token_user(auth_header.split(" ", 1)[1].strip()) if auth_header.startswith("Bearer ") else None
                    if caller and caller["role"] == "admin":
                        final_role = requested_role
                    elif admin_count == 0 and requested_role == "admin":
                        final_role = "admin"
                    else:
                        conn.close()
                        return jsonify({"error": "Solo un administrador autenticado puede asignar roles elevados"}), 403

                user_id = str(uuid.uuid4())
                pwd_hash = generate_password_hash(password, method="pbkdf2:sha256")
                cursor.execute(
                    "INSERT INTO users (id, username, email, password_hash, role) VALUES (%s, %s, %s, %s, %s);",
                    (user_id, username, email, pwd_hash, final_role)
                )
                token = f"sess_{secrets.token_urlsafe(32)}"
                cursor.execute(
                    "INSERT INTO sessions (token, user_id, expires_at) VALUES (%s, %s, DATE_ADD(UTC_TIMESTAMP(), INTERVAL 24 HOUR));",
                    (token, user_id)
                )
            conn.commit()
            conn.close()
            return jsonify({
                "message": "Usuario registrado exitosamente",
                "token": token,
                "user": {"id": user_id, "username": username, "email": email, "role": final_role}
            }), 201
        except Exception as e:
            return jsonify({"error": f"Error en base de datos RDS: {str(e)}"}), 500

    @app.route("/api/v1/auth/login", methods=["POST"])
    def login():
        data = request.get_json() or {}
        username = (data.get("username") or "").strip()
        password = data.get("password") or ""

        if not username or not password:
            return jsonify({"error": "Usuario y contraseña obligatorios"}), 400

        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute(
                    "SELECT id, username, email, password_hash, role FROM users WHERE username = %s;",
                    (username,)
                )
                user = cursor.fetchone()
                if not user or not check_password_hash(user["password_hash"], password):
                    conn.close()
                    return jsonify({"error": "Credenciales inválidas"}), 401

                token = f"sess_{secrets.token_urlsafe(32)}"
                cursor.execute(
                    "INSERT INTO sessions (token, user_id, expires_at) VALUES (%s, %s, DATE_ADD(UTC_TIMESTAMP(), INTERVAL 24 HOUR));",
                    (token, user["id"])
                )
            conn.commit()
            conn.close()
            return jsonify({
                "message": "Autenticación exitosa",
                "token": token,
                "user": {
                    "id": user["id"],
                    "username": user["username"],
                    "email": user["email"],
                    "role": user["role"]
                }
            }), 200
        except Exception as e:
            return jsonify({"error": f"Error en login RDS: {str(e)}"}), 500

    @app.route("/api/v1/auth/logout", methods=["POST"])
    @require_auth()
    def logout():
        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute("DELETE FROM sessions WHERE token = %s;", (g.auth_token,))
            conn.commit()
            conn.close()
            return jsonify({"message": "Sesión cerrada correctamente"}), 200
        except Exception as e:
            return jsonify({"error": str(e)}), 500

    @app.route("/api/v1/auth/me", methods=["GET"])
    @require_auth()
    def me():
        return jsonify({"user": g.current_user}), 200

    @app.route("/api/v1/users", methods=["GET"])
    @require_auth(roles=["admin"])
    def list_users():
        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute("SELECT id, username, email, role, created_at FROM users ORDER BY created_at DESC;")
                users = cursor.fetchall()
            conn.close()
            for u in users:
                if u.get("created_at"):
                    u["created_at"] = str(u["created_at"])
            return jsonify({"users": users, "count": len(users)}), 200
        except Exception as e:
            return jsonify({"error": str(e)}), 500

    @app.route("/api/v1/users/<target_id>/role", methods=["PATCH"])
    @require_auth(roles=["admin"])
    def update_user_role(target_id):
        data = request.get_json() or {}
        new_role = (data.get("role") or "").strip().lower()
        if new_role not in ("admin", "analyst", "user"):
            return jsonify({"error": "Rol inválido (admin, analyst, user)"}), 400
        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute("UPDATE users SET role = %s WHERE id = %s;", (new_role, target_id))
                if cursor.rowcount == 0:
                    conn.close()
                    return jsonify({"error": "Usuario no encontrado"}), 404
            conn.commit()
            conn.close()
            return jsonify({"message": "Rol actualizado", "user_id": target_id, "role": new_role}), 200
        except Exception as e:
            return jsonify({"error": str(e)}), 500

    @app.route("/api/v1/documents/presign", methods=["POST"])
    @require_auth()
    def presign_upload():
        data = request.get_json() or {}
        raw_filename = data.get("filename") or ""
        safe_name = sanitize_filename(raw_filename)
        ext = os.path.splitext(safe_name)[1].lower()
        file_size = data.get("file_size_bytes", 0)
        content_type = (data.get("content_type") or "application/octet-stream").strip()

        if not safe_name or ext not in ALLOWED_EXTENSIONS:
            return jsonify({"error": f"Extensión no permitida. Válidas: {', '.join(sorted(ALLOWED_EXTENSIONS))}"}), 400
        if not isinstance(file_size, int) or file_size <= 0 or file_size > MAX_FILE_BYTES:
            return jsonify({"error": f"Tamaño inválido (1 byte a {MAX_FILE_BYTES // (1024*1024)} MB)"}), 400

        doc_id = str(uuid.uuid4())
        owner = g.current_user["username"]
        s3_key = f"uploads/{owner}/{doc_id}_{safe_name}"

        try:
            presigned_url = s3_client.generate_presigned_url(
                "put_object",
                Params={
                    "Bucket": DOCUMENTS_BUCKET,
                    "Key": s3_key,
                    "ContentType": content_type
                },
                ExpiresIn=300
            )
            return jsonify({
                "document_id": doc_id,
                "s3_key": s3_key,
                "filename": safe_name,
                "presigned_url": presigned_url,
                "content_type": content_type
            }), 200
        except Exception as e:
            return jsonify({"error": f"Error generando Presigned URL S3: {str(e)}", "component": "s3"}), 500

    @app.route("/api/v1/documents", methods=["POST"])
    @require_auth()
    def create_document():
        data = request.get_json() or {}
        owner = g.current_user["username"]
        processing_type = (data.get("processing_type") or "OCR_FULL").strip()
        priority = (data.get("priority") or "NORMAL").strip().upper()
        if priority not in ("HIGH", "NORMAL", "LOW"):
            priority = "NORMAL"

        doc_id = (data.get("document_id") or "").strip() or str(uuid.uuid4())
        s3_key = (data.get("s3_key") or "").strip()
        safe_name = sanitize_filename(data.get("filename") or "")
        ext = os.path.splitext(safe_name)[1].lower()
        file_content_b64 = data.get("file_content")

        if not safe_name or ext not in ALLOWED_EXTENSIONS:
            return jsonify({"error": "Nombre o extensión de archivo inválida"}), 400

        # Modo Presigned URL (flujo principal SPA) vs Fallback Base64 explícito (CLI)
        if s3_key:
            expected_prefix = f"uploads/{owner}/"
            if not s3_key.startswith(expected_prefix) and g.current_user["role"] != "admin":
                return jsonify({"error": "s3_key no pertenece al usuario autenticado"}), 403
            try:
                head = s3_client.head_object(Bucket=DOCUMENTS_BUCKET, Key=s3_key)
                file_size_bytes = head["ContentLength"]
            except ClientError as ce:
                code = ce.response.get("Error", {}).get("Code", "")
                status_code = 400 if code in ("404", "NoSuchKey", "NotFound") else 500
                return jsonify({"error": f"Objeto no verificado en S3 ({code}): {str(ce)}", "component": "s3"}), status_code
        elif file_content_b64:
            try:
                payload = base64.b64decode(file_content_b64, validate=True)
            except Exception:
                return jsonify({"error": "file_content Base64 inválido"}), 400
            if len(payload) == 0 or len(payload) > MAX_FILE_BYTES:
                return jsonify({"error": "Tamaño de archivo fuera de rango (1B - 10MB)"}), 400
            file_size_bytes = len(payload)
            s3_key = f"uploads/{owner}/{doc_id}_{safe_name}"
            try:
                s3_client.put_object(
                    Bucket=DOCUMENTS_BUCKET,
                    Key=s3_key,
                    Body=payload,
                    Metadata={"doc_id": doc_id, "user_id": owner, "filename": safe_name}
                )
            except Exception as s3_err:
                return jsonify({"error": f"Fallo persistiendo en Amazon S3: {str(s3_err)}", "component": "s3"}), 500
        else:
            return jsonify({"error": "Debe subir primero el archivo vía /api/v1/documents/presign o enviar file_content"}), 400

        file_size_kb = max(1, round(file_size_bytes / 1024))
        created_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

        # 1. Persistir estado inicial en DynamoDB (fallo real -> HTTP 500)
        try:
            dynamodb_table.put_item(
                Item={
                    "document_id": doc_id,
                    "user_id": owner,
                    "filename": safe_name,
                    "status": "QUEUED",
                    "s3_key": s3_key,
                    "processing_type": processing_type,
                    "priority": priority,
                    "file_size_kb": file_size_kb,
                    "created_at": created_at
                }
            )
        except Exception as ddb_err:
            return jsonify({"error": f"Fallo persistiendo en DynamoDB: {str(ddb_err)}", "component": "dynamodb"}), 500

        # 2. Persistir en RDS MySQL para cola transaccional con SKIP LOCKED
        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute("""
                    INSERT INTO documents (id, user_id, filename, status, s3_key, processing_type, priority, file_size_kb)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s);
                """, (doc_id, owner, safe_name, "QUEUED", s3_key, processing_type, priority, file_size_kb))
            conn.commit()
            conn.close()
        except Exception as db_err:
            return jsonify({"error": f"Fallo persistiendo en RDS MySQL: {str(db_err)}", "component": "rds"}), 500

        return jsonify({
            "message": "Documento almacenado en S3 y encolado en DynamoDB + RDS",
            "document_id": doc_id,
            "filename": safe_name,
            "status": "QUEUED",
            "s3_key": s3_key,
            "file_size_kb": file_size_kb,
            "created_at": created_at
        }), 202

    @app.route("/api/v1/documents", methods=["GET"])
    @require_auth()
    def list_documents():
        role = g.current_user["role"]
        username = g.current_user["username"]
        try:
            conn = get_db()
            with conn.cursor() as cursor:
                if role in ("admin", "analyst"):
                    cursor.execute("SELECT * FROM documents ORDER BY created_at DESC LIMIT 50;")
                else:
                    cursor.execute("SELECT * FROM documents WHERE user_id = %s ORDER BY created_at DESC LIMIT 50;", (username,))
                docs = cursor.fetchall()
            conn.close()
            for d in docs:
                if d.get("created_at"):
                    d["created_at"] = str(d["created_at"])
                if d.get("updated_at"):
                    d["updated_at"] = str(d["updated_at"])
            return jsonify({"documents": docs, "count": len(docs)}), 200
        except Exception as e:
            return jsonify({"error": f"Error consultando historial: {str(e)}"}), 500

    @app.route("/api/v1/documents/<doc_id>", methods=["GET"])
    @require_auth()
    def get_document(doc_id):
        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute("SELECT * FROM documents WHERE id = %s;", (doc_id,))
                doc = cursor.fetchone()
            conn.close()
            if not doc:
                return jsonify({"error": "Documento no encontrado"}), 404
            if g.current_user["role"] not in ("admin", "analyst") and doc["user_id"] != g.current_user["username"]:
                return jsonify({"error": "Acceso denegado a documento ajeno"}), 403
            if doc.get("created_at"):
                doc["created_at"] = str(doc["created_at"])
            if doc.get("updated_at"):
                doc["updated_at"] = str(doc["updated_at"])
            try:
                ddb_res = dynamodb_table.get_item(Key={"document_id": doc_id})
                if "Item" in ddb_res:
                    doc["dynamodb_item"] = ddb_res["Item"]
            except Exception as ddb_err:
                doc["dynamodb_error"] = str(ddb_err)
            return jsonify(doc), 200
        except Exception as e:
            return jsonify({"error": str(e)}), 500

    if __name__ == "__main__":
        app.run(host="0.0.0.0", port=80)
PYEOF

    echo "=== [3/6] GENERANDO CODIGO WORKER DE PROCESAMIENTO ASINCRONO ==="
    cat << 'PYEOF' | sed 's/^    //' > /opt/docuprocess/worker.py
    import os
    import re
    import io
    import time
    import json
    import struct
    import zipfile
    import hashlib
    import urllib.request
    import boto3
    import pymysql

    REGION = os.getenv("AWS_DEFAULT_REGION", "us-east-1")
    DOCUMENTS_BUCKET = os.getenv("DOCUMENTS_BUCKET", "")
    DYNAMODB_TABLE = os.getenv("DYNAMODB_TABLE", "docuprocess-metadata")
    SNS_TOPIC_ARN = os.getenv("SNS_TOPIC_ARN", "")
    DB_HOST = os.getenv("DB_HOST", "")
    DB_USER = os.getenv("DB_USER", "")
    DB_PASS = os.getenv("DB_PASSWORD", "")
    DB_NAME = os.getenv("DB_NAME", "")
    ALERT_EMAIL = os.getenv("ALERT_EMAIL", "azgomez2015@gmail.com")

    def get_instance_id():
        try:
            req = urllib.request.Request(
                "http://169.254.169.254/latest/api/token",
                method="PUT",
                headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"}
            )
            token = urllib.request.urlopen(req, timeout=1).read().decode()
            req2 = urllib.request.Request(
                "http://169.254.169.254/latest/meta-data/instance-id",
                headers={"X-aws-ec2-metadata-token": token}
            )
            return urllib.request.urlopen(req2, timeout=1).read().decode()
        except Exception:
            return os.uname().nodename

    INSTANCE_ID = get_instance_id()

    def get_db():
        return pymysql.connect(
            host=DB_HOST,
            user=DB_USER,
            password=DB_PASS,
            database=DB_NAME,
            cursorclass=pymysql.cursors.DictCursor,
            autocommit=False,
            connect_timeout=5
        )

    dynamodb = boto3.resource("dynamodb", region_name=REGION)
    dynamodb_table = dynamodb.Table(DYNAMODB_TABLE)
    s3_client = boto3.client("s3", region_name=REGION)
    sns_client = boto3.client("sns", region_name=REGION)

    def inspect_document_bytes(filename, body):
        if not body:
            raise ValueError("El archivo almacenado en S3 está vacío (0 bytes)")
        if "force_fail" in filename.lower() or b"DOCUPROCESS_FORCE_FAIL" in body[:512]:
            raise ValueError("Marcador de fallo documental detectado en contenido/nombre")

        ext = os.path.splitext(filename)[1].lower()
        sha256_hex = hashlib.sha256(body).hexdigest()
        size_kb = max(1, round(len(body) / 1024))
        meta = {"extension": ext, "bytes": len(body)}
        pages = 1

        if ext == ".pdf":
            if not body.startswith(b"%PDF-"):
                raise ValueError("Archivo PDF corrupto: cabecera '%PDF-' ausente")
            pdf_ver = body[:8].decode("ascii", errors="ignore").strip()
            page_matches = re.findall(rb"/Type\s*/Page\b", body)
            pages = max(1, len(page_matches))
            meta["pdf_version"] = pdf_ver
            meta["detected_objects"] = len(re.findall(rb"\d+\s+\d+\s+obj\b", body))
        elif ext == ".txt":
            text = body.decode("utf-8", errors="replace")
            lines = text.splitlines()
            words = len(text.split())
            pages = max(1, (len(lines) + 39) // 40)
            meta["lines"] = len(lines)
            meta["words"] = words
        elif ext == ".png":
            if len(body) < 24 or body[:8] != b"\x89PNG\r\n\x1a\n":
                raise ValueError("Archivo PNG corrupto: firma mágica inválida")
            w, h = struct.unpack(">II", body[16:24])
            meta["dimensions"] = f"{w}x{h}px"
        elif ext in (".jpg", ".jpeg"):
            if len(body) < 4 or body[:2] != b"\xff\xd8":
                raise ValueError("Archivo JPEG corrupto: marcador SOI ausente")
            meta["format"] = "JPEG"
        elif ext == ".docx":
            if not body.startswith(b"PK\x03\x04"):
                raise ValueError("Archivo DOCX corrupto: estructura ZIP inválida")
            with zipfile.ZipFile(io.BytesIO(body)) as zf:
                names = zf.namelist()
                meta["zip_entries"] = len(names)
                pages = max(1, sum(1 for n in names if n.startswith("word/")) // 3)
        elif ext == ".doc":
            if not body.startswith(b"\xd0\xcf\x11\xe0"):
                raise ValueError("Archivo DOC corrupto: cabecera OLE2 inválida")

        return pages, size_kb, sha256_hex, json.dumps(meta, ensure_ascii=False)

    def send_sns_notification(subject, message):
        resp = sns_client.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=subject[:100],
            Message=message
        )
        return resp.get("MessageId", "")

    print(f"=== [DOCUPROCESS ASYNC WORKER] INICIADO EN {INSTANCE_ID} ===")

    while True:
        conn = None
        claimed_doc = None
        try:
            conn = get_db()
            with conn.cursor() as cursor:
                # Bloqueo pesimista atómico para evitar condición de carrera entre instancias del ASG
                cursor.execute("""
                    SELECT id, user_id, filename, s3_key, processing_type, priority
                    FROM documents
                    WHERE status = 'QUEUED'
                    ORDER BY FIELD(priority, 'HIGH', 'NORMAL', 'LOW'), created_at ASC
                    LIMIT 1
                    FOR UPDATE SKIP LOCKED;
                """)
                claimed_doc = cursor.fetchone()
                if claimed_doc:
                    cursor.execute(
                        "UPDATE documents SET status = 'PROCESSING', worker_instance = %s WHERE id = %s;",
                        (INSTANCE_ID, claimed_doc["id"])
                    )
            conn.commit()
        except Exception as claim_err:
            if conn:
                try:
                    conn.rollback()
                except Exception:
                    pass
            print(f"[Worker Claim Error] {claim_err}")
            time.sleep(3)
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

        if not claimed_doc:
            time.sleep(3)
            continue

        doc_id = claimed_doc["id"]
        filename = claimed_doc["filename"]
        user_id = claimed_doc["user_id"]
        s3_key = claimed_doc.get("s3_key") or ""
        print(f"--> [WORKER {INSTANCE_ID}] Procesando {doc_id} ({filename}) desde s3://{DOCUMENTS_BUCKET}/{s3_key}")

        try:
            # 1. Actualizar DynamoDB a PROCESSING
            dynamodb_table.update_item(
                Key={"document_id": doc_id},
                UpdateExpression="SET #st = :p, worker_instance = :wi",
                ExpressionAttributeNames={"#st": "status"},
                ExpressionAttributeValues={":p": "PROCESSING", ":wi": INSTANCE_ID}
            )

            if not s3_key:
                raise ValueError("s3_key vacío: no hay objeto referenciado en S3")

            # 2. Descargar bytes reales desde Amazon S3 y calcular hash/metadatos reales
            s3_obj = s3_client.get_object(Bucket=DOCUMENTS_BUCKET, Key=s3_key)
            body_bytes = s3_obj["Body"].read()
            pages, size_kb, doc_hash, meta_json = inspect_document_bytes(filename, body_bytes)

            # 3. Persistir métricas reales en Amazon DynamoDB
            completed_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            dynamodb_table.update_item(
                Key={"document_id": doc_id},
                UpdateExpression="SET #st = :c, pages_count = :pg, file_size_kb = :sz, ocr_status = :ocr, sha256_hash = :sh, metadata_summary = :ms, worker_instance = :wi, completed_at = :ca",
                ExpressionAttributeNames={"#st": "status"},
                ExpressionAttributeValues={
                    ":c": "COMPLETED",
                    ":pg": pages,
                    ":sz": size_kb,
                    ":ocr": "SUCCESS",
                    ":sh": doc_hash,
                    ":ms": meta_json,
                    ":wi": INSTANCE_ID,
                    ":ca": completed_at
                }
            )

            # 4. Notificación SNS de éxito (solo marca notification_sent=1 si SNS responde OK)
            sns_sent = 0
            sns_warn = ""
            try:
                subject = f"[DocuProcess Cloud] Documento Procesado: {filename}"
                message = (
                    f"DocuProcess Cloud - Procesamiento Exitoso\n"
                    f"===========================================\n"
                    f"ID Documento:   {doc_id}\n"
                    f"Archivo:        {filename}\n"
                    f"Usuario:        {user_id}\n"
                    f"Objeto S3:      s3://{DOCUMENTS_BUCKET}/{s3_key}\n"
                    f"Tamaño Real:    {size_kb} KB\n"
                    f"Páginas:        {pages}\n"
                    f"SHA-256 Real:   {doc_hash}\n"
                    f"Metadatos:      {meta_json}\n"
                    f"Worker EC2:     {INSTANCE_ID}\n"
                    f"Destinatario:   {ALERT_EMAIL}\n"
                    f"Fecha UTC:      {completed_at}\n"
                )
                msg_id = send_sns_notification(subject, message)
                sns_sent = 1
                dynamodb_table.update_item(
                    Key={"document_id": doc_id},
                    UpdateExpression="SET notification_sent = :ns, sns_message_id = :mid",
                    ExpressionAttributeValues={":ns": True, ":mid": msg_id}
                )
                print(f"--> [SNS OK] {doc_id} MessageId={msg_id}")
            except Exception as sns_err:
                sns_warn = f"SNS error: {str(sns_err)}"
                print(f"[SNS Warning] {sns_err}")

            # 5. Confirmar estado final en RDS MySQL
            c2 = get_db()
            with c2.cursor() as cursor:
                cursor.execute("""
                    UPDATE documents
                    SET status = 'COMPLETED', file_size_kb = %s, pages_count = %s, ocr_status = 'SUCCESS',
                        sha256_hash = %s, metadata_summary = %s, error_message = %s, notification_sent = %s
                    WHERE id = %s;
                """, (size_kb, pages, doc_hash, meta_json, sns_warn or None, sns_sent, doc_id))
            c2.commit()
            c2.close()
            print(f"--> [WORKER {INSTANCE_ID}] Completado {doc_id} (sha256={doc_hash[:12]}...)")

        except Exception as proc_err:
            err_msg = str(proc_err)[:500]
            failed_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            print(f"[WORKER FAILED] {doc_id}: {err_msg}")

            # Persistir FAILED en DynamoDB
            try:
                dynamodb_table.update_item(
                    Key={"document_id": doc_id},
                    UpdateExpression="SET #st = :f, ocr_status = :ocr, error_message = :em, worker_instance = :wi, failed_at = :fa",
                    ExpressionAttributeNames={"#st": "status"},
                    ExpressionAttributeValues={
                        ":f": "FAILED",
                        ":ocr": "FAILED",
                        ":em": err_msg,
                        ":wi": INSTANCE_ID,
                        ":fa": failed_at
                    }
                )
            except Exception as ddb_fail_err:
                print(f"[DynamoDB Fail Update Error] {ddb_fail_err}")

            # Publicar alerta SNS de fallo
            sns_fail_sent = 0
            try:
                fail_subj = f"[DocuProcess Cloud] FALLO de Procesamiento: {filename}"
                fail_msg = (
                    f"DocuProcess Cloud - Alerta de Error en Procesamiento\n"
                    f"====================================================\n"
                    f"ID Documento:   {doc_id}\n"
                    f"Archivo:        {filename}\n"
                    f"Usuario:        {user_id}\n"
                    f"Objeto S3:      s3://{DOCUMENTS_BUCKET}/{s3_key}\n"
                    f"Worker EC2:     {INSTANCE_ID}\n"
                    f"Detalle Error:  {err_msg}\n"
                    f"Fecha UTC:      {failed_at}\n"
                )
                send_sns_notification(fail_subj, fail_msg)
                sns_fail_sent = 1
                print(f"--> [SNS FAILURE ALERT SENT] {doc_id}")
            except Exception as sns_fail_err:
                print(f"[SNS Failure Alert Error] {sns_fail_err}")

            # Actualizar RDS MySQL a FAILED
            try:
                c3 = get_db()
                with c3.cursor() as cursor:
                    cursor.execute("""
                        UPDATE documents
                        SET status = 'FAILED', ocr_status = 'FAILED', error_message = %s, notification_sent = %s
                        WHERE id = %s;
                    """, (err_msg, sns_fail_sent, doc_id))
                c3.commit()
                c3.close()
            except Exception as db_fail_err:
                print(f"[DB Fail Update Error] {db_fail_err}")
PYEOF

    # Permisos estrictos para usuario sin privilegios
    chown -R docuprocess:docuprocess /opt/docuprocess
    chmod 750 /opt/docuprocess
    chmod 640 /opt/docuprocess/.env
    chmod 644 /opt/docuprocess/app.py /opt/docuprocess/worker.py

    echo "=== [4/6] CONFIGURANDO SERVICIOS SYSTEMD (NON-ROOT) ==="
    cat << 'SVCEOF' | sed 's/^    //' > /etc/systemd/system/docuprocess-api.service
    [Unit]
    Description=DocuProcess REST API Service
    After=network.target

    [Service]
    User=docuprocess
    Group=docuprocess
    AmbientCapabilities=CAP_NET_BIND_SERVICE
    CapabilityBoundingSet=CAP_NET_BIND_SERVICE
    NoNewPrivileges=true
    WorkingDirectory=/opt/docuprocess
    Environment=PYTHONUNBUFFERED=1
    EnvironmentFile=/opt/docuprocess/.env
    ExecStart=/usr/local/bin/gunicorn --bind 0.0.0.0:80 --workers 2 --timeout 60 app:app
    Restart=always

    [Install]
    WantedBy=multi-user.target
SVCEOF

    cat << 'SVCEOF' | sed 's/^    //' > /etc/systemd/system/docuprocess-worker.service
    [Unit]
    Description=DocuProcess Async Processing Worker
    After=network.target

    [Service]
    User=docuprocess
    Group=docuprocess
    NoNewPrivileges=true
    WorkingDirectory=/opt/docuprocess
    Environment=PYTHONUNBUFFERED=1
    EnvironmentFile=/opt/docuprocess/.env
    ExecStart=/usr/bin/python3 -u worker.py
    Restart=always

    [Install]
    WantedBy=multi-user.target
SVCEOF

    echo "=== [5/6] INICIANDO SERVICIOS ==="
    systemctl daemon-reload
    systemctl enable --now docuprocess-api.service
    systemctl enable --now docuprocess-worker.service
    echo "=== [6/6] PROVISIÓN DE SOFTWARE FINALIZADA CON ÉXITO ==="
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.name_prefix}-asg-instance"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Auto Scaling Group (min 2, max 4, desired 2) en subredes privadas
resource "aws_autoscaling_group" "backend" {
  name_prefix         = "${local.name_prefix}-asg-"
  vpc_zone_identifier = aws_subnet.private_compute[*].id
  target_group_arns   = [aws_lb_target_group.api.arn]

  min_size         = 2
  max_size         = 4
  desired_capacity = 2

  health_check_type         = "ELB"
  health_check_grace_period = 300
  force_delete              = true

  launch_template {
    id      = aws_launch_template.backend.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-asg-node"
    propagate_at_launch = true
  }
}

### ==============================================================================
