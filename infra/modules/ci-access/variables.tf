variable "project_name" {
  type = string
}

variable "ecr_repository_arns" {
  description = "ARNs dos 5 repositórios ECR aos quais o usuário de CI pode dar push"
  type        = list(string)
}

variable "cluster_name" {
  description = "Nome do cluster EKS onde o auto-reparo vai rodar `kubectl rollout restart`"
  type        = string
}

variable "cluster_arn" {
  description = "ARN do cluster EKS (permite eks:DescribeCluster para gerar o kubeconfig)"
  type        = string
}

variable "app_namespace" {
  description = "Namespace da aplicação: único lugar onde o usuário de CI tem permissão de edição no cluster"
  type        = string
  default     = "toggle-app"
}
