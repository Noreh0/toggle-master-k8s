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

## Depois do apply: bootstrap do cluster

Tudo o que não é Terraform nem GitOps (ArgoCD, metrics-server, ingress, Secrets, schemas dos bancos e as
Applications do ArgoCD) é feito por um único script, idempotente:

```bash
cp scripts/bootstrap.env.example scripts/bootstrap.env   # preencha (o arquivo é ignorado pelo Git)
scripts/bootstrap.sh            # cluster completo
scripts/bootstrap.sh ci-keys    # access key nova do usuário de CI -> Secrets do GitHub (gh)
scripts/bootstrap.sh ci         # reconstrói as 5 imagens no ECR (que volta vazio a cada destroy)
scripts/bootstrap.sh service-key
scripts/bootstrap.sh status
scripts/bootstrap.sh ui         # ArgoCD (8080), Grafana (3000) e Prometheus (9090) no navegador
```

Os nodes são `t3.large` (`node_instance_types`, `node_desired_size`, `node_min_size`, `node_max_size`):
com `t3.medium` o limite de 17 pods por node estoura com ArgoCD + observabilidade + apps.

## O que é criado
- VPC com subnets públicas/privadas, IGW e NAT Gateway (`modules/networking`)
- Cluster EKS + Node Group com IAM roles próprias (`modules/eks`)
- 3 instâncias RDS Postgres (`modules/rds`)
- 1 cluster Redis ElastiCache (`modules/elasticache`)
- 1 tabela DynamoDB `ToggleMasterAnalytics` (`modules/dynamodb`)
- 1 fila SQS + 1 DLQ (mensagens que falham 5 vezes vão para a DLQ) (`modules/sqs`)
- 5 repositórios ECR, um por microsserviço (`modules/ecr`)
- Add-on `eks-pod-identity-agent` (`modules/eks`) e roles de menor privilégio para os pods
  `evaluation-service` (só `sqs:SendMessage`) e `analytics-service` (consome o SQS e grava
  no DynamoDB), ligados às ServiceAccounts do namespace `toggle-app` (`modules/workload-iam`)

## Permissões dos pods (EKS Pod Identity)
Os pods não usam access key. As ServiceAccounts `evaluation-service` e `analytics-service`
(criadas junto dos Deployments no GitOps) são associadas aos roles acima. Se renomear uma
ServiceAccount, atualize `modules/workload-iam/main.tf` para o nome continuar batendo.

## Segredos que mudam a cada `destroy`/`apply`
Os endpoints de RDS e ElastiCache são novos a cada criação. Depois do `apply`, recrie o Secret
`app-secrets` (ver `k8s/01-secrets.yaml`) com os valores dos outputs `rds_endpoints` e
`redis_endpoint` (`REDIS_URL` = `redis://<redis_endpoint>:6379`).

## Para destruir tudo (evitar custo)
```bash
terraform destroy
```
