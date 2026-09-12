variable "project_name" {
  type = string
}

variable "ecr_repository_arns" {
  description = "ARNs dos 5 repositórios ECR aos quais o usuário de CI pode dar push"
  type        = list(string)
}
