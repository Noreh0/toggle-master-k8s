# Runbook — Do Terraform ao ArgoCD sincronizando

Siga NESSA ORDEM. Cada passo só faz sentido depois do anterior.

## 0. Subir os repositórios pro GitHub

O CI (GitHub Actions) só roda dentro de um repositório do GitHub, e o ArgoCD
precisa de uma URL de git real pra monitorar. Crie os dois repositórios no
GitHub (podem ser privados) e dê push:

```bash
# repositório principal
cd toggle-master-k8s
git init   # se ainda não tiver .git
git add .
git commit -m "estrutura inicial fase 3"
git remote add origin https://github.com/SEU_USUARIO/toggle-master-k8s.git
git push -u origin main

# repositório GitOps (separado)
cd ../toggle-master-gitops
git init
git add .
git commit -m "manifests iniciais"
git remote add origin https://github.com/SEU_USUARIO/toggle-master-gitops.git
git push -u origin main
```

Depois, edite os 5 arquivos em `argocd/*.yaml` trocando `SEU_USUARIO` pela
URL real do seu repositório GitOps.

## 1. Criar a infraestrutura

```bash
cd infra
terraform init
terraform apply
```

Guarde a saída (`terraform output`) — você vai precisar de:
- `eks_cluster_name`
- `rds_endpoints`
- `redis_endpoint`
- `sqs_queue_url`
- `ecr_repository_urls`
- `ci_user_name` (usado no próximo passo)

## 1.1. Gerar a Access Key do usuário de CI (uma vez, fora do Terraform)

O Terraform já criou o usuário IAM `toggle-master-ci` com a policy mínima
(só push nos 5 repositórios ECR). A chave em si não é criada pelo Terraform
de propósito — se fosse, o Secret Access Key ficaria salvo em texto no
`terraform.tfstate`. Gere manualmente:

```bash
aws iam create-access-key --user-name toggle-master-ci
```

Isso devolve um `AccessKeyId` e um `SecretAccessKey` — **aparecem só essa
vez**, copie na hora. Também pegue o ID da sua conta:

```bash
aws sts get-caller-identity --query Account --output text
```

No GitHub, vá em **Settings → Secrets and variables → Actions** do
repositório principal e cadastre:

| Tipo | Nome | Valor |
|---|---|---|
| Secret | `AWS_ACCESS_KEY_ID` | o `AccessKeyId` gerado acima |
| Secret | `AWS_SECRET_ACCESS_KEY` | o `SecretAccessKey` gerado acima |
| Secret | `AWS_ACCOUNT_ID` | o número de 12 dígitos da sua conta |
| Secret | `GITOPS_PAT` | um Personal Access Token seu, escopo `repo` |
| Variable | `GITOPS_REPO` | `SEU_USUARIO/toggle-master-gitops` |

(Personal Access Token: GitHub → Settings da sua conta → Developer settings
→ Personal access tokens → Generate new token, escopo `repo`.)

## 2. Apontar o kubectl para o cluster novo

```bash
aws eks update-kubeconfig --name toggle-master --region us-east-1
kubectl get nodes   # tem que listar 2 nodes
```

## 3. Bootstrap manual do namespace + secrets (uma vez só, NUNCA automatizado)

Isso é feito manualmente e fora do Git de propósito: segredo real não pode ir pro
repositório GitOps.

```bash
kubectl apply -f k8s/00-namespace.yaml
```

Agora, faça uma cópia LOCAL do arquivo de secrets (não edite o do git):

```bash
cp k8s/01-secrets.yaml k8s/01-secrets.local.yaml
```

Abra `k8s/01-secrets.local.yaml` e troque os `REPLACE_WITH_...` pelos valores reais:
- `AUTH_DB_URL`, `FLAG_DB_URL`, `TARGETING_DB_URL`: monte a partir do endpoint de
  `rds_endpoints` do terraform, no formato
  `postgres://usuario:senha@ENDPOINT:5432/nome_do_banco`.
- `MASTER_KEY`: invente uma senha forte qualquer (é a chave mestra do auth-service).
- `SERVICE_API_KEY`: **ainda não dá pra preencher** — só existe depois que o
  auth-service estiver no ar (passo 6).

Aplique:
```bash
kubectl apply -f k8s/01-secrets.local.yaml
```

Adicione ao `.gitignore` da raiz do projeto: `k8s/01-secrets.local.yaml` — ele
nunca deve ser commitado.

## 4. Instalar o ArgoCD no cluster (uma vez só)

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd get pods -w   # espere todos ficarem "Running"
```

Pegue a senha inicial do usuário `admin`:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```
u8zvZDr7sqynyTfb

Acesse a UI (numa aba de terminal separada, deixe rodando):
```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```
Abra https://localhost:8080 e logue com `admin` + a senha acima.

## 5. Editar os manifests das Applications do ArgoCD

Antes de aplicar, edite os 5 arquivos em `argocd/*.yaml` e troque:
```yaml
repoURL: https://github.com/SEU_USUARIO/toggle-master-gitops.git
```
pelo link real do SEU repositório GitOps.

Também garanta que os workflows do CI (`.github/workflows/ci-*.yaml`) já
conseguem dar push nas imagens (secrets configurados — veja a rodada anterior).

## 6. Primeiro build manual (antes de existir CI passando)

Como as imagens ainda não existem no ECR na primeira vez, rode manualmente uma
vez para cada serviço (só a primeira vez; depois disso o CI assume):
```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com

docker build -t toggle-master-auth services/auth
docker tag toggle-master-auth:latest <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/toggle-master-auth:latest
docker push <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/toggle-master-auth:latest
```
Repita para os outros 4 serviços.

## 7. Aplicar as 5 Applications do ArgoCD

```bash
kubectl apply -f argocd/
argocd app list      # ou veja na UI — as 5 devem aparecer
```

O ArgoCD vai puxar o repositório GitOps e criar Deployment + Service de cada
serviço no namespace `toggle-app`.

## 8. Criar a SERVICE_API_KEY de verdade

Agora que o `auth-service` está rodando, crie a chave real que o `evaluation`
vai usar:
```bash
kubectl -n toggle-app port-forward svc/auth-service 8001:8001
curl -X POST http://localhost:8001/keys \
  -H "Authorization: Bearer <MASTER_KEY que você definiu no passo 3>" \
  -H "Content-Type: application/json" \
  -d '{"name": "evaluation-service"}'
```
Copie o `key` retornado (só aparece uma vez!), coloque em
`k8s/01-secrets.local.yaml` no campo `SERVICE_API_KEY`, e reaplique:
```bash
kubectl apply -f k8s/01-secrets.local.yaml
kubectl -n toggle-app rollout restart deployment evaluation-service
```

## 9. Testar o ciclo completo de GitOps

Faça uma alteração pequena em qualquer serviço (ex: um log a mais) → `git push`
→ acompanhe o Actions rodando → confira que ele commitou a nova tag no repo
GitOps → veja o ArgoCD detectar e sincronizar sozinho (não precisa apertar
nada na UI, o `selfHeal`/`automated` já faz isso).

## Para não gerar custo depois de gravar o vídeo

```bash
kubectl delete -f argocd/          # remove as Applications
helm uninstall argocd -n argocd 2>/dev/null || kubectl delete ns argocd
cd infra && terraform destroy
```
