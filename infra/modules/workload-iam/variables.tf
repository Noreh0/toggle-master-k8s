variable "project_name" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "namespace" {
  description = "Namespace onde os serviços rodam (precisa bater com os manifests do GitOps)"
  type        = string
  default     = "toggle-app"
}

variable "queue_arn" {
  description = "ARN da fila SQS de eventos de avaliação"
  type        = string
}

variable "table_arn" {
  description = "ARN da tabela DynamoDB de analytics"
  type        = string
}
