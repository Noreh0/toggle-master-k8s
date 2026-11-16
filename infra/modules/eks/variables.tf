variable "project_name" {
  type = string
}

variable "eks_cluster_version" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "node_instance_types" {
  type = list(string)
}

variable "node_desired_size" {
  description = "Quantidade desejada de nodes no node group"
  type        = number
}

variable "node_min_size" {
  description = "Mínimo de nodes no node group"
  type        = number
}

variable "node_max_size" {
  description = "Máximo de nodes no node group"
  type        = number
}
