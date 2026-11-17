#!/usr/bin/env bash
# Recria o "estado manual" do cluster depois de um `terraform apply`:
# kubeconfig, metrics-server, ingress-nginx, ArgoCD, Secrets, db-init e as Applications do ArgoCD
# (apps + observabilidade). Tudo idempotente: pode rodar de novo sem estragar nada.
#
# Uso:  scripts/bootstrap.sh [fase]
#   all (padrão)  tudo, na ordem certa
#   ci-keys       gera a access key do usuário de CI e grava nos Secrets do GitHub (precisa do gh)
#   ci            dispara os 5 workflows de CI (reconstroem as imagens no ECR vazio; precisa do gh)
#   service-key   cria a SERVICE_API_KEY no auth-service, grava no Secret e reinicia o evaluation
#   ui            abre port-forward do ArgoCD (https://localhost:8080) e do Grafana (http://localhost:3000)
#   passwords     mostra as senhas do ArgoCD e do Grafana
#   status        mostra o estado das Applications e dos pods
#
# Requisitos: bash, aws, kubectl, terraform, openssl, curl (gh nas fases ci-keys/ci).
# Segredos: variáveis de ambiente ou o arquivo scripts/bootstrap.env (fora do Git; veja o .example).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA="$ROOT/infra"

ENV_FILE="${BOOTSTRAP_ENV_FILE:-$ROOT/scripts/bootstrap.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # tr remove o CR caso o arquivo tenha sido salvo com fim de linha do Windows
  # shellcheck disable=SC1090
  source <(tr -d '\r' <"$ENV_FILE")
  set +a
fi

REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT_NAME:-toggle-master}"
GITHUB_REPO="${GITHUB_REPO:-Noreh0/toggle-master-k8s}"
NS_APP="toggle-app"
NS_MON="monitoring"
SERVICES=(auth flag targeting evaluation analytics)

# Versões dos componentes instalados fora do Helm. Podem ser sobrescritas por variável de ambiente.
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.4.8}"
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.8.0}"
# O ingress-nginx foi aposentado pelo projeto Kubernetes em março/2026 (não recebe mais correções).
# Segue aqui só por continuidade com a Fase 3; a demo da Fase 4 não depende dele.
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.13.0}"
INSTALL_INGRESS="${INSTALL_INGRESS:-true}"
SERVICE_KEY_WAIT="${SERVICE_KEY_WAIT:-180s}"

PLACEHOLDER_SERVICE_KEY="pendente-rode-bootstrap-service-key"

# ---------------------------------------------------------------- utilidades
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[aviso]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[erro]\033[0m %s\n' "$*" >&2; exit 1; }

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' não encontrado no PATH."
  done
}

tf_out() { terraform -chdir="$INFRA" output -raw "$1"; }

# Lê uma chave de um Secret já existente (vazio se não existir).
secret_value() { # <namespace> <secret> <chave>
  kubectl -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 --decode 2>/dev/null || true
}

# Pede o valor sem ecoar no terminal quando a variável ainda não foi definida.
ask_secret() { # <variável> <descrição>
  local var="$1" label="$2"
  if [[ -z "${!var:-}" ]]; then
    [[ -t 0 ]] || die "$var não definida (defina em $ENV_FILE ou no ambiente)."
    # shellcheck disable=SC2229  # indireção intencional: lê para a variável cujo nome está em $var
    read -r -s -p "$label: " "$var"
    echo
    export "${var?}"
  fi
}

urlencode() {
  local s="$1" i c hex out=""
  local LC_ALL=C
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

ensure_namespace() { kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }

# ---------------------------------------------------------------- fases
phase_preflight() {
  log "Conferindo ferramentas e credenciais"
  need aws kubectl terraform openssl curl
  aws sts get-caller-identity --query Arn --output text >/dev/null \
    || die "Credenciais AWS inválidas (aws configure / aws sso login)."
  tf_out eks_cluster_name >/dev/null 2>&1 \
    || die "Não consegui ler os outputs do Terraform em $INFRA. Rode 'terraform init && terraform apply' antes."
  info "OK"
}

phase_cluster() {
  log "Conectando ao cluster"
  CLUSTER_NAME="$(tf_out eks_cluster_name)"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null
  until kubectl get nodes --no-headers 2>/dev/null | grep -q .; do
    info "aguardando os nodes registrarem..."
    sleep 10
  done
  kubectl wait --for=condition=Ready nodes --all --timeout=600s
  kubectl get nodes
}

phase_addons() {
  log "metrics-server ${METRICS_SERVER_VERSION} (necessário para o HPA)"
  kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml" >/dev/null
  kubectl -n kube-system rollout status deploy/metrics-server --timeout=300s

  if [[ "$INSTALL_INGRESS" == "true" ]]; then
    log "ingress-nginx ${INGRESS_NGINX_VERSION}"
    kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/aws/deploy.yaml" >/dev/null
    kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s
  else
    info "INSTALL_INGRESS=false: pulando o ingress-nginx"
  fi

  log "ArgoCD ${ARGOCD_VERSION}"
  ensure_namespace argocd
  # server-side: os CRDs do ArgoCD são grandes demais para o apply comum
  kubectl apply --server-side --force-conflicts -n argocd \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null
  kubectl wait --for=condition=established --timeout=120s crd/applications.argoproj.io
  kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
  kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
  kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
}

phase_secrets() {
  log "Namespaces e Secrets da aplicação"
  ensure_namespace "$NS_APP"
  ensure_namespace "$NS_MON"

  local db_user="${DB_USER:-toggleadmin}"
  DB_PASSWORD="${DB_PASSWORD:-${TF_VAR_db_password:-}}"
  if [[ -z "$DB_PASSWORD" && -f "$INFRA/terraform.tfvars" ]]; then
    DB_PASSWORD="$(sed -n 's/^[[:space:]]*db_password[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$INFRA/terraform.tfvars" | head -n1)"
  fi
  ask_secret DB_PASSWORD "Senha do RDS (db_password)"

  local inst host url_auth url_flag url_targeting
  for inst in auth-db flag-db targeting-db; do
    host="$(aws rds describe-db-instances --region "$REGION" \
      --db-instance-identifier "${PROJECT}-${inst}" \
      --query 'DBInstances[0].Endpoint.Address' --output text)"
    [[ -n "$host" && "$host" != "None" ]] || die "RDS ${PROJECT}-${inst} sem endpoint."
    case "$inst" in
      auth-db)      url_auth="postgres://${db_user}:$(urlencode "$DB_PASSWORD")@${host}:5432/${inst//-/_}" ;;
      flag-db)      url_flag="postgres://${db_user}:$(urlencode "$DB_PASSWORD")@${host}:5432/${inst//-/_}" ;;
      targeting-db) url_targeting="postgres://${db_user}:$(urlencode "$DB_PASSWORD")@${host}:5432/${inst//-/_}" ;;
    esac
  done
  local redis_url
  redis_url="redis://$(tf_out redis_endpoint):6379"

  # MASTER_KEY e SERVICE_API_KEY são reaproveitadas se o Secret já existir.
  local master_key service_key
  master_key="$(secret_value "$NS_APP" app-secrets MASTER_KEY)"
  [[ -n "$master_key" ]] || master_key="${MASTER_KEY:-$(openssl rand -hex 24)}"
  service_key="$(secret_value "$NS_APP" app-secrets SERVICE_API_KEY)"
  [[ -n "$service_key" ]] || service_key="$PLACEHOLDER_SERVICE_KEY"

  kubectl -n "$NS_APP" create secret generic app-secrets \
    --from-literal=AUTH_DB_URL="$url_auth" \
    --from-literal=FLAG_DB_URL="$url_flag" \
    --from-literal=TARGETING_DB_URL="$url_targeting" \
    --from-literal=MASTER_KEY="$master_key" \
    --from-literal=SERVICE_API_KEY="$service_key" \
    --from-literal=REDIS_URL="$redis_url" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  info "app-secrets ($NS_APP) ok"

  log "Secrets da observabilidade"
  ask_secret NEW_RELIC_LICENSE_KEY "New Relic license key (ingest)"
  kubectl -n "$NS_MON" create secret generic newrelic-license \
    --from-literal=NEW_RELIC_LICENSE_KEY="$NEW_RELIC_LICENSE_KEY" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  info "newrelic-license ($NS_MON) ok"

  local grafana_pass
  grafana_pass="$(secret_value "$NS_MON" grafana-admin admin-password)"
  [[ -n "$grafana_pass" ]] || grafana_pass="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)"
  kubectl -n "$NS_MON" create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$grafana_pass" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  info "grafana-admin ($NS_MON) ok"

  # Valores vazios derrubariam o provisionamento dos contact points no start do Grafana,
  # então entram valores de preenchimento (os envios para esses canais simplesmente falham).
  local pd_key="${PAGERDUTY_INTEGRATION_KEY:-}" discord_url="${DISCORD_WEBHOOK_URL:-}" gh_token="${GITHUB_DISPATCH_TOKEN:-}"
  [[ -n "$pd_key" ]] || { warn "PAGERDUTY_INTEGRATION_KEY vazia: o incidente não será criado."; pd_key="nao-configurado"; }
  [[ -n "$discord_url" ]] || { warn "DISCORD_WEBHOOK_URL vazia: sem aviso no Discord."; discord_url="http://localhost/nao-configurado"; }
  [[ -n "$gh_token" ]] || { warn "GITHUB_DISPATCH_TOKEN vazia: o auto-reparo não será disparado."; gh_token="nao-configurado"; }
  kubectl -n "$NS_MON" create secret generic grafana-alerting-secrets \
    --from-literal=PAGERDUTY_INTEGRATION_KEY="$pd_key" \
    --from-literal=DISCORD_WEBHOOK_URL="$discord_url" \
    --from-literal=GITHUB_DISPATCH_TOKEN="$gh_token" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  info "grafana-alerting-secrets ($NS_MON) ok"
}

phase_dbinit() {
  log "Schemas dos bancos (db-init)"
  local svc
  for svc in auth flag targeting; do
    kubectl -n "$NS_APP" create configmap "${svc}-db-init" \
      --from-file=init.sql="$ROOT/services/$svc/db/init.sql" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
  kubectl -n "$NS_APP" delete job db-init --ignore-not-found >/dev/null
  kubectl apply -f "$ROOT/k8s/09-db-init-job.yaml" >/dev/null
  if ! kubectl -n "$NS_APP" wait --for=condition=complete job/db-init --timeout=300s; then
    kubectl -n "$NS_APP" logs job/db-init --tail=50 || true
    die "db-init falhou (veja o log acima)."
  fi
  info "schemas criados"
}

phase_apps() {
  log "Applications do ArgoCD (apps + observabilidade)"
  kubectl apply -f "$ROOT/argocd/"
  info "o ArgoCD agora sincroniza os apps e a stack de observabilidade a partir do repo GitOps (branch main)"

  if [[ "$INSTALL_INGRESS" == "true" ]]; then
    log "Ingress e HPA"
    local i
    for i in 1 2 3 4 5 6; do
      if kubectl apply -f "$ROOT/k8s/07-ingress.yaml" >/dev/null 2>&1; then break; fi
      info "webhook do ingress ainda subindo, tentando de novo ($i/6)..."
      sleep 10
    done
    kubectl apply -f "$ROOT/k8s/07-ingress.yaml" >/dev/null
  fi
  kubectl apply -f "$ROOT/k8s/08-hpa.yaml" >/dev/null
}

phase_service_key() {
  log "SERVICE_API_KEY do evaluation-service"
  need curl
  local current
  current="$(secret_value "$NS_APP" app-secrets SERVICE_API_KEY)"
  if [[ -n "$current" && "$current" != "$PLACEHOLDER_SERVICE_KEY" ]]; then
    info "já existe uma SERVICE_API_KEY no Secret; nada a fazer"
    return 0
  fi
  if ! kubectl -n "$NS_APP" wait --for=condition=available deploy/auth-service --timeout="$SERVICE_KEY_WAIT"; then
    warn "auth-service ainda não está disponível (provavelmente a imagem ainda não existe no ECR)."
    warn "Depois que o CI publicar as imagens, rode:  scripts/bootstrap.sh service-key"
    return 0
  fi

  local master_key
  master_key="$(secret_value "$NS_APP" app-secrets MASTER_KEY)"
  [[ -n "$master_key" ]] || die "MASTER_KEY não encontrada no Secret app-secrets."

  kubectl -n "$NS_APP" port-forward svc/auth-service 18001:8001 >/dev/null 2>&1 &
  local pf=$!
  # shellcheck disable=SC2064
  trap "kill $pf 2>/dev/null || true" RETURN
  local i
  for i in $(seq 1 20); do
    curl -fs http://127.0.0.1:18001/health >/dev/null 2>&1 && break
    sleep 1
  done

  local resp key
  resp="$(curl -fsS -X POST http://127.0.0.1:18001/admin/keys \
    -H "Authorization: Bearer ${master_key}" -H 'Content-Type: application/json' \
    -d '{"name":"evaluation-service"}')" || die "POST /admin/keys falhou."
  key="$(printf '%s' "$resp" | sed -n 's/.*"key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [[ -n "$key" ]] || die "Não consegui extrair a chave da resposta do auth-service."

  kubectl -n "$NS_APP" patch secret app-secrets --type merge \
    -p "{\"stringData\":{\"SERVICE_API_KEY\":\"${key}\"}}" >/dev/null
  kubectl -n "$NS_APP" rollout restart deploy/evaluation-service >/dev/null
  info "SERVICE_API_KEY criada e evaluation-service reiniciado"
}

phase_ci_keys() {
  log "Access key do usuário de CI -> Secrets do GitHub"
  need gh aws terraform
  local user id secret
  user="$(tf_out ci_user_name)"
  read -r id secret < <(aws iam create-access-key --user-name "$user" \
    --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
  [[ -n "$id" && -n "$secret" ]] || die "Falha ao criar a access key de $user."
  printf '%s' "$id" | gh secret set AWS_ACCESS_KEY_ID --repo "$GITHUB_REPO"
  printf '%s' "$secret" | gh secret set AWS_SECRET_ACCESS_KEY --repo "$GITHUB_REPO"
  info "AWS_ACCESS_KEY_ID e AWS_SECRET_ACCESS_KEY atualizados em $GITHUB_REPO (os valores não foram exibidos)"
}

phase_ci() {
  log "Disparando o CI dos 5 serviços (precisa estar na branch main com workflow_dispatch)"
  need gh
  local svc
  for svc in "${SERVICES[@]}"; do
    gh workflow run "ci-${svc}.yaml" --repo "$GITHUB_REPO" --ref main
    info "ci-${svc} disparado"
  done
  info "acompanhe em https://github.com/${GITHUB_REPO}/actions"
}

phase_passwords() {
  log "Credenciais"
  info "ArgoCD  usuário: admin   senha: $(secret_value argocd argocd-initial-admin-secret password)"
  info "Grafana usuário: admin   senha: $(secret_value "$NS_MON" grafana-admin admin-password)"
}

phase_ui() {
  need kubectl
  phase_passwords
  log "Port-forward (Ctrl+C para encerrar)"
  info "ArgoCD   https://localhost:8080"
  info "Grafana  http://localhost:3000"
  info "Prometheus http://localhost:9090"
  trap 'kill $(jobs -p) 2>/dev/null || true' EXIT INT TERM
  kubectl -n argocd port-forward svc/argocd-server 8080:443 >/dev/null &
  kubectl -n "$NS_MON" port-forward svc/kube-prometheus-stack-grafana 3000:80 >/dev/null &
  kubectl -n "$NS_MON" port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null &
  wait
}

phase_status() {
  log "Applications do ArgoCD"
  kubectl -n argocd get applications
  log "Pods que não estão Running/Completed"
  kubectl get pods -A --no-headers | grep -Ev 'Running|Completed' || info "todos os pods estão Running"
}

phase_summary() {
  log "Pronto"
  local lb
  lb="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o 'jsonpath={.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -z "$lb" ]] || info "Entrada HTTP (NLB): http://${lb}  (/auth, /flags, /targeting, /evaluation)"
  phase_passwords
  cat <<EOF

Próximos passos:
  1. scripts/bootstrap.sh ci-keys   # só uma vez por 'terraform apply' (usuário de CI novo)
  2. scripts/bootstrap.sh ci        # reconstrói as 5 imagens no ECR vazio
  3. scripts/bootstrap.sh service-key
  4. scripts/bootstrap.sh status    # espere tudo Synced/Healthy
  5. scripts/bootstrap.sh ui        # ArgoCD e Grafana no navegador
EOF
}

# ---------------------------------------------------------------- principal
case "${1:-all}" in
  all)
    phase_preflight
    phase_cluster
    phase_addons
    phase_secrets
    phase_dbinit
    phase_apps
    phase_service_key
    phase_summary
    ;;
  ci-keys)     phase_ci_keys ;;
  ci)          phase_ci ;;
  service-key) phase_service_key ;;
  ui)          phase_ui ;;
  passwords)   phase_passwords ;;
  status)      phase_status ;;
  -h|--help|help) sed -n '2,19p' "${BASH_SOURCE[0]}" ;;
  *) die "fase desconhecida: $1 (use --help)" ;;
esac
