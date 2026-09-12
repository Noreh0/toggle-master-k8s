terraform {
  required_version = ">= 1.9.0"

  # Requisito de estado remoto (Aula 2 de IaC):
  # o bucket abaixo precisa existir ANTES do `terraform init`.
  # Crie-o manualmente uma vez (console, cli, ou um projeto Terraform
  # separado de "bootstrap") com versionamento habilitado.
  backend "s3" {
    bucket       = "toggle-master-tfstate-SEUNOME" # troque por um nome único global
    key          = "infra/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true # lock nativo do backend S3 (substitui DynamoDB lock table)
    encrypt      = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
