resource "aws_dynamodb_table" "analytics" {
  name         = "ToggleMasterAnalytics"
  billing_mode = "PAY_PER_REQUEST" # on-demand, evita gerenciar capacity manualmente
  hash_key     = "event_id" # o analytics-service grava `event_id` (uuid) como chave de cada evento

  attribute {
    name = "event_id"
    type = "S"
  }

  tags = {
    Name = "ToggleMasterAnalytics"
  }
}
