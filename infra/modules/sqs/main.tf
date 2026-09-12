resource "aws_sqs_queue" "main" {
  name                       = "${var.project_name}-queue"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 345600 # 4 dias

  tags = {
    Name = "${var.project_name}-queue"
  }
}
