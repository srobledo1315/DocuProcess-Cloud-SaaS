### ==============================================================================
### 11. OUTPUTS
### ==============================================================================

output "frontend_cdn_domain" {
  value       = "https://${aws_cloudfront_distribution.frontend.domain_name}"
  description = "Dominio publico de CloudFront para acceder al Frontend estatico"
}

output "frontend_s3_bucket" {
  value       = aws_s3_bucket.frontend.id
  description = "Nombre del bucket S3 para desplegar la compilacion del Frontend"
}

output "backend_alb_dns" {
  value       = "http://${aws_lb.api.dns_name}"
  description = "Punto de entrada publico HTTP del Application Load Balancer para la API REST"
}

output "rds_mysql_endpoint" {
  value       = aws_db_instance.mysql.endpoint
  description = "Endpoint de conexion privada a la base de datos relacional MySQL"
}

output "dynamodb_table_name" {
  value       = aws_dynamodb_table.metadata.name
  description = "Nombre de la tabla NoSQL DynamoDB para metadatos de documentos"
}

output "documents_s3_bucket" {
  value       = aws_s3_bucket.documents.id
  description = "Bucket S3 para almacenamiento seguro de documentos de clientes"
}

output "sns_alerts_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "ARN del topico SNS para recepcion de alertas operativas"
}

output "ssm_command_connect" {
  value       = "aws ssm start-session --target <instance_id>"
  description = "Comando CLI para conexion segura por SSM Session Manager sin puerto 22 SSH"
}
