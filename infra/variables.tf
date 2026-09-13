variable "aws_region" {
  description = "Região AWS onde tudo será criado"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefixo usado no nome dos recursos"
  type        = string
  default     = "toggle-master"
}

variable "vpc_cidr" {
  description = "CIDR block da VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZs usadas para as subnets"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "microservices" {
  description = "Os 5 microsserviços do ToggleMaster"
  type        = list(string)
  default     = ["auth", "flag", "targeting", "evaluation", "analytics"]
}

variable "eks_cluster_version" {
  description = "Versão do Kubernetes no EKS. Mantenha uma versão em suporte padrão (checar https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html)"
  type        = string
  default     = "1.34"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "db_instances" {
  description = "As 3 instâncias RDS Postgres pedidas no desafio"
  type        = list(string)
  default     = ["auth-db", "flag-db", "targeting-db"]
}

variable "db_username" {
  type      = string
  default   = "toggleadmin"
  sensitive = true
}

variable "db_password" {
  description = "Senha do RDS. Em produção, use AWS Secrets Manager em vez de variável de texto."
  type        = string
  sensitive   = true
  # Não coloque valor default em texto puro aqui.
  # Passe via terraform.tfvars (fora do git) ou variável de ambiente TF_VAR_db_password.
}
