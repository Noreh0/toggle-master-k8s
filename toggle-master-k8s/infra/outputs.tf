output "vpc_id" {
  value = module.networking.vpc_id
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "rds_endpoints" {
  value = module.rds.endpoints
}

output "redis_endpoint" {
  value = module.elasticache.redis_endpoint
}

output "dynamodb_table_name" {
  value = module.dynamodb.table_name
}

output "sqs_queue_url" {
  value = module.sqs.queue_url
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "ci_user_name" {
  description = "Nome do usuário IAM a ser usado no GitHub Actions (gere a access key manualmente)"
  value       = module.ci_access.ci_user_name
}
