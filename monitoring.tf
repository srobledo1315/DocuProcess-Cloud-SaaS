### ==============================================================================
### 8. NOTIFICATIONS & EVENT STREAMING (AMAZON SNS)
### ==============================================================================

# Tópico SNS para Notificaciones Operativas y Alertas de Procesamiento Documental
resource "aws_sns_topic" "alerts" {
  name = "docuprocess-alerts"

  tags = {
    Name = "${local.name_prefix}-alerts-topic"
  }
}

# Suscripción por correo electrónico a alertas
resource "aws_sns_topic_subscription" "email_alerts" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}


### ==============================================================================
### 10. MONITORING, SCALING & AUDITING (CLOUDWATCH, ASG POLICIES, CLOUDTRAIL)
### ==============================================================================

# Política de Escalado hacia arriba (Scale-Out)
resource "aws_autoscaling_policy" "scale_up" {
  name                   = "${local.name_prefix}-scale-up"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.backend.name
}

# Alarma de CPU Alta para EC2 (> 75%)
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${local.name_prefix}-ec2-cpu-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 75
  alarm_description   = "Escalar ASG si la CPU supera el 75% durante 4 minutos"
  alarm_actions       = [aws_autoscaling_policy.scale_up.arn, aws_sns_topic.alerts.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.backend.name
  }
}

# Política de Escalado hacia abajo (Scale-In)
resource "aws_autoscaling_policy" "scale_down" {
  name                   = "${local.name_prefix}-scale-down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.backend.name
}

# Alarma de CPU Baja para EC2 (< 25%)
resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "${local.name_prefix}-ec2-cpu-low"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 25
  alarm_description   = "Reducir ASG si la CPU cae por debajo del 25% durante 4 minutos"
  alarm_actions       = [aws_autoscaling_policy.scale_down.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.backend.name
  }
}

# Alarma de CPU de Base de Datos RDS MySQL (> 80%)
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${local.name_prefix}-rds-cpu-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Alerta por saturacion de computo en base de datos transaccional RDS"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.mysql.identifier
  }
}

# Alarma de Almacenamiento Libre en RDS (< 5 GB)
resource "aws_cloudwatch_metric_alarm" "rds_storage_low" {
  alarm_name          = "${local.name_prefix}-rds-storage-low"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 5000000000 # 5 GB en bytes
  alarm_description   = "Alerta de capacidad de almacenamiento en disco para RDS MySQL"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.mysql.identifier
  }
}

# Auditoría Global con AWS CloudTrail
# NOTA SANDBOX: Vocareum deniega 'cloudtrail:CreateTrail' a nivel de política de identidad.
# Se mantiene la estructura declarativa con count = 0 para total compatibilidad.
resource "aws_cloudtrail" "main" {
  count                         = 0
  name                          = "${local.name_prefix}-cloudtrail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_logging                = true

  depends_on = [aws_s3_bucket_policy.cloudtrail]

  tags = {
    Name = "${local.name_prefix}-cloudtrail"
  }
}

### ==============================================================================
