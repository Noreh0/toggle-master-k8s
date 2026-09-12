output "repository_urls" {
  description = "Mapa microsserviço -> URL do repositório ECR"
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "repository_arns" {
  description = "Mapa microsserviço -> ARN do repositório ECR"
  value       = { for k, v in aws_ecr_repository.this : k => v.arn }
}
