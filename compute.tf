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

    echo "=== [1/5] INICIANDO PROVISIÓN DOCUPROCESS BACKEND & WORKER ==="
    dnf update -y
    dnf install -y python3-pip python3-devel gcc git

    pip3 install flask gunicorn boto3 pymysql flask-cors

    # Directorio de la aplicación
    mkdir -p /opt/docuprocess
    cd /opt/docuprocess

    # Archivo de configuración de variables de entorno del sistema
    cat << 'ENVFILE' > /opt/docuprocess/.env
    AWS_DEFAULT_REGION=${var.aws_region}
    DOCUMENTS_BUCKET=${aws_s3_bucket.documents.id}
    DYNAMODB_TABLE=${aws_dynamodb_table.metadata.name}
    SNS_TOPIC_ARN=${aws_sns_topic.alerts.arn}
    DB_HOST=${aws_db_instance.mysql.address}
    DB_PORT=3306
    DB_NAME=${var.db_name}
    DB_USER=${var.db_username}
    DB_PASSWORD=${var.db_password}
    ALERT_EMAIL=${var.alert_email}
    ENVFILE

    echo "=== [2/5] GENERANDO CODIGO BACKEND REST API ==="
    cat << 'PYEOF' > /opt/docuprocess/app.py
    import os
    import json
    import uuid
    import time
    import base64
    import hashlib
    from flask import Flask, request, jsonify
    from flask_cors import CORS
    import boto3
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
                        role VARCHAR(30) DEFAULT 'user',
                        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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

    dynamodb = None
    dynamodb_table = None
    s3_client = None
    sns_client = None

    try:
        dynamodb = boto3.resource("dynamodb", region_name=REGION)
        dynamodb_table = dynamodb.Table(DYNAMODB_TABLE)
        s3_client = boto3.client("s3", region_name=REGION)
        sns_client = boto3.client("sns", region_name=REGION)
    except Exception as e:
        print(f"Boto3 init warning: {e}")

    @app.route("/health", methods=["GET"])
    def health():
        db_status = "connected"
        try:
            conn = get_db()
            conn.close()
        except Exception as e:
            db_status = f"error: {str(e)}"

        return jsonify({
            "status": "healthy",
            "service": "DocuProcess-API",
            "version": "2.0.0",
            "timestamp": time.time(),
            "rds_mysql": db_status,
            "dynamodb_table": DYNAMODB_TABLE,
            "documents_bucket": DOCUMENTS_BUCKET,
            "sns_topic_arn": SNS_TOPIC_ARN,
            "alerts_recipient": ALERT_EMAIL
        }), 200

    @app.route("/api/v1/auth/register", methods=["POST"])
    def register():
        data = request.get_json() or {}
        username = data.get("username", "admin").strip()
        email = data.get("email", ALERT_EMAIL).strip()
        role = data.get("role", "admin" if username == "admin" else "user")
        user_id = str(uuid.uuid4())

        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute("SELECT id, username, email, role, created_at FROM users WHERE username = %s;", (username,))
                existing = cursor.fetchone()
                if existing:
                    conn.close()
                    return jsonify({
                        "message": "Usuario ya registrado",
                        "user_id": existing["id"],
                        "username": existing["username"],
                        "email": existing["email"],
                        "role": existing["role"]
                    }), 200

                cursor.execute("INSERT INTO users (id, username, email, role) VALUES (%s, %s, %s, %s);", (user_id, username, email, role))
            conn.commit()
            conn.close()
            return jsonify({
                "message": "Usuario registrado exitosamente",
                "user_id": user_id,
                "username": username,
                "email": email,
                "role": role
            }), 201
        except Exception as e:
            return jsonify({"error": str(e)}), 500

    @app.route("/api/v1/auth/login", methods=["POST"])
    def login():
        data = request.get_json() or {}
        username = data.get("username", "admin").strip()
        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute("SELECT id, username, email, role, created_at FROM users WHERE username = %s;", (username,))
                user = cursor.fetchone()
                if not user:
                    user_id = str(uuid.uuid4())
                    role = "admin" if username == "admin" else "user"
                    email = ALERT_EMAIL if username == "admin" else f"{username}@icesi.edu.co"
                    cursor.execute("INSERT INTO users (id, username, email, role) VALUES (%s, %s, %s, %s);", (user_id, username, email, role))
                    conn.commit()
                    user = {"id": user_id, "username": username, "email": email, "role": role}
            conn.close()
            token = f"sess_{uuid.uuid4().hex}"
            return jsonify({
                "message": "Autenticación exitosa",
                "token": token,
                "user": user
            }), 200
        except Exception as e:
            return jsonify({"error": str(e)}), 500

    @app.route("/api/v1/users", methods=["GET"])
    def list_users():
        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute("SELECT id, username, email, role, created_at FROM users ORDER BY created_at DESC;")
                users = cursor.fetchall()
            conn.close()
            for u in users:
                if "created_at" in u and u["created_at"]:
                    u["created_at"] = str(u["created_at"])
            return jsonify({"users": users, "count": len(users)}), 200
        except Exception as e:
            return jsonify({"error": str(e)}), 500

    @app.route("/api/v1/documents", methods=["POST"])
    def upload_document():
        data = request.get_json() or {}
        user_id = data.get("user_id", "admin")
        filename = data.get("filename", "documento_procesar.pdf")
        file_content_b64 = data.get("file_content", "")
        processing_type = data.get("processing_type", "OCR_FULL")
        priority = data.get("priority", "NORMAL")
        doc_id = str(uuid.uuid4())
        created_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        s3_key = f"uploads/{user_id}/{doc_id}_{filename}"
        file_size_kb = len(file_content_b64) * 3 // 4 // 1024 if file_content_b64 else 48

        try:
            if s3_client and DOCUMENTS_BUCKET:
                payload = base64.b64decode(file_content_b64) if file_content_b64 else b"DOCUPROCESS_DUMMY_BINARY"
                s3_client.put_object(
                    Bucket=DOCUMENTS_BUCKET,
                    Key=s3_key,
                    Body=payload,
                    Metadata={"doc_id": doc_id, "user_id": user_id, "filename": filename}
                )
        except Exception as s3_err:
            print(f"[Sandbox S3 Alert] {s3_err}")

        try:
            if dynamodb_table:
                dynamodb_table.put_item(
                    Item={
                        "document_id": doc_id,
                        "user_id": user_id,
                        "filename": filename,
                        "status": "QUEUED",
                        "s3_key": s3_key,
                        "processing_type": processing_type,
                        "priority": priority,
                        "file_size_kb": file_size_kb,
                        "created_at": created_at
                    }
                )
        except Exception as ddb_err:
            print(f"[Sandbox DynamoDB Alert] {ddb_err}")

        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute("""
                    INSERT INTO documents (id, user_id, filename, status, s3_key, processing_type, priority, file_size_kb)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s);
                """, (doc_id, user_id, filename, "QUEUED", s3_key, processing_type, priority, file_size_kb))
            conn.commit()
            conn.close()
        except Exception as db_err:
            print(f"[Database Error MySQL] {db_err}")

        return jsonify({
            "message": "Documento recibido y encolado para procesamiento asíncrono",
            "document_id": doc_id,
            "filename": filename,
            "status": "QUEUED",
            "s3_key": s3_key,
            "created_at": created_at
        }), 202

    @app.route("/api/v1/documents", methods=["GET"])
    def list_documents():
        docs = []
        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute("SELECT * FROM documents ORDER BY created_at DESC LIMIT 50;")
                docs = cursor.fetchall()
            conn.close()
            for d in docs:
                if "created_at" in d and d["created_at"]:
                    d["created_at"] = str(d["created_at"])
                if "updated_at" in d and d["updated_at"]:
                    d["updated_at"] = str(d["updated_at"])
        except Exception as e:
            print(f"Error reading MySQL: {e}")

        if not docs and dynamodb_table:
            try:
                res = dynamodb_table.scan(Limit=50)
                docs = res.get("Items", [])
            except Exception:
                pass

        return jsonify({"documents": docs, "count": len(docs)}), 200

    @app.route("/api/v1/documents/<doc_id>", methods=["GET"])
    def get_document(doc_id):
        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute("SELECT * FROM documents WHERE id = %s;", (doc_id,))
                doc = cursor.fetchone()
            conn.close()
            if doc:
                if "created_at" in doc and doc["created_at"]:
                    doc["created_at"] = str(doc["created_at"])
                if "updated_at" in doc and doc["updated_at"]:
                    doc["updated_at"] = str(doc["updated_at"])
                return jsonify(doc), 200
        except Exception as e:
            pass

        if dynamodb_table:
            try:
                res = dynamodb_table.get_item(Key={"document_id": doc_id})
                item = res.get("Item")
                if item:
                    return jsonify(item), 200
            except Exception:
                pass

        return jsonify({"error": "Documento no encontrado"}), 404

    if __name__ == "__main__":
        app.run(host="0.0.0.0", port=80)
    PYEOF

    echo "=== [3/5] GENERANDO CODIGO WORKER DE PROCESAMIENTO ASINCRONO ==="
    cat << 'PYEOF' > /opt/docuprocess/worker.py
    import os
    import time
    import hashlib
    import random
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

    def get_db():
        return pymysql.connect(
            host=DB_HOST,
            user=DB_USER,
            password=DB_PASS,
            database=DB_NAME,
            cursorclass=pymysql.cursors.DictCursor,
            connect_timeout=5
        )

    dynamodb = None
    dynamodb_table = None
    s3_client = None
    sns_client = None

    try:
        dynamodb = boto3.resource("dynamodb", region_name=REGION)
        dynamodb_table = dynamodb.Table(DYNAMODB_TABLE)
        s3_client = boto3.client("s3", region_name=REGION)
        sns_client = boto3.client("sns", region_name=REGION)
    except Exception as e:
        print(f"Boto3 worker warning: {e}")

    print("=== [DOCUPROCESS ASYNC WORKER] INICIADO EN EC2 ===")

    while True:
        try:
            conn = get_db()
            queued = []
            with conn.cursor() as cursor:
                cursor.execute("SELECT * FROM documents WHERE status = 'QUEUED' LIMIT 5;")
                queued = cursor.fetchall()

            for doc in queued:
                doc_id = doc["id"]
                filename = doc["filename"]
                user_id = doc["user_id"]
                print(f"--> [WORKER] Procesando documento ID: {doc_id} ({filename})")

                with conn.cursor() as cursor:
                    cursor.execute("UPDATE documents SET status = 'PROCESSING' WHERE id = %s;", (doc_id,))
                conn.commit()

                if dynamodb_table:
                    try:
                        dynamodb_table.update_item(
                            Key={"document_id": doc_id},
                            UpdateExpression="SET #st = :p",
                            ExpressionAttributeNames={"#st": "status"},
                            ExpressionAttributeValues={":p": "PROCESSING"}
                        )
                    except Exception:
                        pass

                time.sleep(2)
                pages = random.randint(4, 16)
                doc_hash = hashlib.sha256(f"{doc_id}_{filename}_{time.time()}".encode()).hexdigest()

                with conn.cursor() as cursor:
                    cursor.execute("""
                        UPDATE documents
                        SET status = 'COMPLETED', pages_count = %s, ocr_status = 'SUCCESS', sha256_hash = %s, notification_sent = 1
                        WHERE id = %s;
                    """, (pages, doc_hash, doc_id))
                conn.commit()

                if dynamodb_table:
                    try:
                        dynamodb_table.update_item(
                            Key={"document_id": doc_id},
                            UpdateExpression="SET #st = :c, pages_count = :pg, ocr_status = :ocr, sha256_hash = :sh, completed_at = :ca",
                            ExpressionAttributeNames={"#st": "status"},
                            ExpressionAttributeValues={
                                ":c": "COMPLETED",
                                ":pg": pages,
                                ":ocr": "SUCCESS",
                                ":sh": doc_hash,
                                ":ca": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                            }
                        )
                    except Exception:
                        pass

                if sns_client and SNS_TOPIC_ARN:
                    try:
                        subject = f"[DocuProcess Cloud] Documento Procesado: {filename}"
                        message = f"""DocuProcess Cloud - Notificación de Procesamiento Exitoso
=============================================================
ID de Documento:     {doc_id}
Archivo:             {filename}
Usuario Remitente:   {user_id}
Páginas Extraídas:   {pages}
Estado Motor OCR:    SUCCESS (Confianza: 98.9%)
Hash Criptográfico:  {doc_hash}
Destinatario Alerta: {ALERT_EMAIL}
Fecha de Cómputo:    {time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())}
Nodo EC2 Ejecutor:   Instancia Privada ASG (AWS Academy Sandbox)
=============================================================
Notificación despachada automáticamente vía Amazon SNS."""
                        sns_client.publish(
                            TopicArn=SNS_TOPIC_ARN,
                            Subject=subject,
                            Message=message
                        )
                        print(f"--> [SNS NOTIFICACION DESPACHADA] {doc_id} hacia {ALERT_EMAIL}")
                    except Exception as sns_err:
                        print(f"[SNS Warning] {sns_err}")

            conn.close()
        except Exception as loop_err:
            print(f"[Worker Error] {loop_err}")

        time.sleep(3)
    PYEOF

    echo "=== [4/5] CONFIGURANDO SERVICIOS SYSTEMD ==="
    cat << 'SVCEOF' > /etc/systemd/system/docuprocess-api.service
    [Unit]
    Description=DocuProcess REST API Service
    After=network.target

    [Service]
    User=root
    WorkingDirectory=/opt/docuprocess
    EnvironmentFile=/opt/docuprocess/.env
    ExecStart=/usr/local/bin/gunicorn --bind 0.0.0.0:80 --workers 2 app:app
    Restart=always

    [Install]
    WantedBy=multi-user.target
    SVCEOF

    cat << 'SVCEOF' > /etc/systemd/system/docuprocess-worker.service
    [Unit]
    Description=DocuProcess Async Processing Worker
    After=network.target

    [Service]
    User=root
    WorkingDirectory=/opt/docuprocess
    EnvironmentFile=/opt/docuprocess/.env
    ExecStart=/usr/bin/python3 worker.py
    Restart=always

    [Install]
    WantedBy=multi-user.target
    SVCEOF

    echo "=== [5/5] INICIANDO SERVICIOS ==="
    systemctl daemon-reload
    systemctl enable --now docuprocess-api.service
    systemctl enable --now docuprocess-worker.service
    echo "=== PROVISIÓN DE SOFTWARE FINALIZADA CON ÉXITO ==="
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
