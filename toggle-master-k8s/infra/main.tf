module "networking" {
  source = "./modules/networking"

  project_name          = var.project_name
  vpc_cidr              = var.vpc_cidr
  availability_zones    = var.availability_zones
  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
}

module "eks" {
  source = "./modules/eks"

  project_name         = var.project_name
  eks_cluster_version  = var.eks_cluster_version
  public_subnet_ids    = module.networking.public_subnet_ids
  private_subnet_ids   = module.networking.private_subnet_ids
  node_instance_types  = var.node_instance_types
}

module "rds" {
  source = "./modules/rds"

  project_name        = var.project_name
  vpc_id              = module.networking.vpc_id
  vpc_cidr            = var.vpc_cidr
  private_subnet_ids  = module.networking.private_subnet_ids
  db_instances        = var.db_instances
  db_username         = var.db_username
  db_password         = var.db_password
}

module "elasticache" {
  source = "./modules/elasticache"

  project_name        = var.project_name
  vpc_id              = module.networking.vpc_id
  vpc_cidr            = var.vpc_cidr
  private_subnet_ids  = module.networking.private_subnet_ids
}

module "dynamodb" {
  source = "./modules/dynamodb"
}

module "sqs" {
  source = "./modules/sqs"

  project_name = var.project_name
}

module "ecr" {
  source = "./modules/ecr"

  project_name  = var.project_name
  microservices = var.microservices
}

module "ci_access" {
  source = "./modules/ci-access"

  project_name         = var.project_name
  ecr_repository_arns  = values(module.ecr.repository_arns)
}
