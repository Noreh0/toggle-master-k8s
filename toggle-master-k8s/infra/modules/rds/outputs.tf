output "endpoints" {
  description = "Mapa nome-da-instância -> endpoint de conexão"
  value       = { for k, v in aws_db_instance.this : k => v.endpoint }
}
