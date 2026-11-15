# Dead-letter queue: recebe as mensagens que o analytics não conseguiu processar.
# Sem ela, uma mensagem com falha voltava para a fila indefinidamente e o erro ficava invisível.
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.project_name}-queue-dlq"
  message_retention_seconds = 1209600 # 14 dias (máximo), tempo para investigar

  tags = {
    Name = "${var.project_name}-queue-dlq"
  }
}

resource "aws_sqs_queue" "main" {
  name                       = "${var.project_name}-queue"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 345600 # 4 dias

  # Após 5 recebimentos sem delete (falha no processamento) a mensagem vai para a DLQ.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 5
  })

  tags = {
    Name = "${var.project_name}-queue"
  }
}
