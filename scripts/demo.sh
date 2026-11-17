#!/usr/bin/env bash
# Ferramentas para a demo da Fase 4 (carga, falha induzida e recuperação).
#
# Uso:  scripts/demo.sh <comando>
#   seed        cria a flag "enable-new-dashboard" e a regra de 50% (idempotente)
#   load [seg]  gera tráfego (evaluation, flag e targeting) por N segundos (padrão 300; Ctrl+C encerra)
#   chaos on    faz o auth-service responder 500 em /validate (incidente induzido)
#   chaos off   volta ao normal sem reiniciar (o auto-reparo faz isso reiniciando o pod)
#   status      mostra pods do toggle-app e a idade deles (o restart zera a idade)
#
# Roteiro do vídeo: `seed` -> `load` (em um terminal) -> `chaos on` (em outro) -> acompanhar
# Grafana (Firing), PagerDuty, Discord e a execução "Self-healing" na aba Actions do GitHub.
set -Eeuo pipefail

NS="toggle-app"
FLAG="${DEMO_FLAG:-enable-new-dashboard}"
PIDS=()

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31m[erro]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM

secret_value() { kubectl -n "$NS" get secret app-secrets -o "jsonpath={.data.$1}" | base64 --decode; }

# Abre um port-forward em segundo plano e espera o /health responder.
pf() { # <serviço> <porta local> <porta do serviço>
  kubectl -n "$NS" port-forward "svc/$1" "$2:$3" >/dev/null 2>&1 &
  PIDS+=("$!")
  for _ in $(seq 1 30); do
    curl -fs "http://127.0.0.1:$2/health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "port-forward de $1 não respondeu em /health"
}

service_key() {
  local k
  k="$(secret_value SERVICE_API_KEY)"
  [[ -n "$k" && "$k" != pendente-* ]] || die "SERVICE_API_KEY ainda não foi criada (scripts/bootstrap.sh service-key)."
  printf '%s' "$k"
}

cmd_seed() {
  log "Criando flag e regra de demonstração"
  local key code
  key="$(service_key)"
  pf flag-service 18002 8002
  pf targeting-service 18003 8003
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:18002/flags \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$FLAG\",\"description\":\"flag da demo\",\"is_enabled\":true}")"
  info "POST /flags -> $code (201 criada, 409 já existia)"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:18003/rules \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d "{\"flag_name\":\"$FLAG\",\"is_enabled\":true,\"rules\":{\"type\":\"PERCENTAGE\",\"value\":50}}")"
  info "POST /rules -> $code (201 criada, 409 já existia)"
}

cmd_load() {
  local secs="${1:-300}" key n=0 end ok=0 fail=0 c
  key="$(service_key)"
  log "Gerando tráfego por ${secs}s (Ctrl+C encerra)"
  pf evaluation-service 18004 8004
  pf flag-service 18002 8002
  pf targeting-service 18003 8003
  end=$((SECONDS + secs))
  while ((SECONDS < end)); do
    n=$((n + 1))
    # evaluation (Redis, flag-service, targeting-service, SQS) e leituras diretas que validam a chave no auth
    for url in \
      "http://127.0.0.1:18004/evaluate?user_id=user-$((RANDOM % 500))&flag_name=$FLAG" \
      "http://127.0.0.1:18002/flags/$FLAG" \
      "http://127.0.0.1:18003/rules/$FLAG"; do
      c="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $key" "$url" || echo 000)"
      if [[ "$c" == 2* ]]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
    done
    ((n % 10)) || info "requisições: ok=$ok falhas=$fail (último código $c)"
    sleep 0.3
  done
  info "fim: ok=$ok falhas=$fail"
}

cmd_chaos() {
  local mode="${1:-}" enabled master code
  case "$mode" in on) enabled=true ;; off) enabled=false ;; *) die "use: chaos on|off" ;; esac
  master="$(secret_value MASTER_KEY)"
  pf auth-service 18001 8001
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:18001/admin/chaos \
    -H "Authorization: Bearer $master" -H 'Content-Type: application/json' \
    -d "{\"enabled\":$enabled}")"
  [[ "$code" == 2* ]] || die "POST /admin/chaos -> $code (o auth-service foi reiniciado/está sem ENABLE_CHAOS?)"
  info "chaos $mode aplicado (HTTP $code) em $(date +%H:%M:%S)"
}

cmd_status() {
  kubectl -n "$NS" get pods -o wide
}

case "${1:-}" in
  seed)   cmd_seed ;;
  load)   shift; cmd_load "${1:-300}" ;;
  chaos)  shift; cmd_chaos "${1:-}" ;;
  status) cmd_status ;;
  ""|-h|--help|help) sed -n '2,12p' "${BASH_SOURCE[0]}" ;;
  *) die "comando desconhecido: $1 (use --help)" ;;
esac
