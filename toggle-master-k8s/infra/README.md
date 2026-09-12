# Infra ToggleMaster (Terraform)

## Pré-requisitos
- Terraform >= 1.9
- AWS CLI configurado (`aws configure`) com uma conta pessoal com permissões de admin
- Um bucket S3 já criado para o backend remoto (edite o nome em `backend.tf`)

## Passo a passo

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# edite terraform.tfvars e coloque uma senha de banco

terraform init
terraform plan
terraform apply
```

## Depois do apply

```bash
aws eks update-kubeconfig --name toggle-master --region us-east-1
kubectl get nodes
```

## O que é criado
- VPC com subnets públicas/privadas, IGW e NAT Gateway (`modules/networking`)
- Cluster EKS + Node Group com IAM roles próprias (`modules/eks`)
- 3 instâncias RDS Postgres (`modules/rds`)
- 1 cluster Redis ElastiCache (`modules/elasticache`)
- 1 tabela DynamoDB `ToggleMasterAnalytics` (`modules/dynamodb`)
- 1 fila SQS (`modules/sqs`)
- 5 repositórios ECR, um por microsserviço (`modules/ecr`)

## Para destruir tudo (evitar custo)
```bash
terraform destroy
```
