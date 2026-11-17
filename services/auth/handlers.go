package main

import (
//	"crypto/sha256"
//	"encoding/hex"
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"sync/atomic"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

// chaosEnabled simula uma falha interna do serviço (só ligável com ENABLE_CHAOS=true).
// Fica em memória de propósito: reiniciar o pod (self-healing) devolve o serviço ao normal.
var chaosEnabled atomic.Bool

// Estrutura para o corpo da requisição de criação de chave
type CreateKeyRequest struct {
	Name string `json:"name"`
}

// Estrutura para a resposta da criação de chave
type CreateKeyResponse struct {
	Name    string `json:"name"`
	Key     string `json:"key"` // A chave em texto plano é retornada APENAS uma vez
	Message string `json:"message"`
}

// healthHandler é um simples endpoint de verificação de saúde
func (a *App) healthHandler(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	if err := json.NewEncoder(w).Encode(map[string]string{"status": "ok"}); err != nil {
		log.Printf("Erro ao escrever resposta do health check: %v", err)
	}
}

// validateKeyHandler verifica se uma chave de API (enviada via Header) é válida
func (a *App) validateKeyHandler(w http.ResponseWriter, r *http.Request) {
	// Falha injetada (ver chaosHandler): responde 5xx até o pod ser reiniciado.
	if chaosEnabled.Load() {
		log.Println("Falha injetada (chaos): respondendo 500")
		http.Error(w, "Falha interna injetada para teste de self-healing", http.StatusInternalServerError)
		return
	}

	// Extrai a chave do header "Authorization: Bearer <key>"
	authHeader := r.Header.Get("Authorization")
	keyString := strings.TrimPrefix(authHeader, "Bearer ")

	if keyString == "" {
		http.Error(w, "Authorization header não encontrado", http.StatusUnauthorized)
		return
	}

	// Calcula o hash da chave recebida
	keyHash := hashAPIKey(keyString)

	// Verifica se o hash existe no banco de dados
	var id int
	ctx, span := tracer.Start(r.Context(), "SELECT api_keys",
		trace.WithSpanKind(trace.SpanKindClient),
		trace.WithAttributes(
			attribute.String("db.system", "postgresql"),
			attribute.String("db.operation", "SELECT"),
			attribute.String("db.sql.table", "api_keys"),
		),
	)
	err := a.DB.QueryRowContext(ctx, "SELECT id FROM api_keys WHERE key_hash = $1 AND is_active = true", keyHash).Scan(&id)
	if err != nil {
		span.RecordError(err)
		if !errors.Is(err, sql.ErrNoRows) {
			span.SetStatus(codes.Error, err.Error())
		}
	}
	span.End()

	if err != nil {
		// Chave inexistente ou inativa: 401 (erro do cliente)
		if errors.Is(err, sql.ErrNoRows) {
			log.Printf("Falha na validação da chave (hash: %s...): chave inválida ou inativa", keyHash[:6])
			http.Error(w, "Chave de API inválida ou inativa", http.StatusUnauthorized)
			return
		}
		// Qualquer outro erro (banco fora, timeout) é falha NOSSA: 503, para aparecer como 5xx nas métricas/alertas
		log.Printf("Erro ao consultar o banco na validação da chave: %v", err)
		http.Error(w, "Serviço de validação indisponível", http.StatusServiceUnavailable)
		return
	}

	// Chave válida
	w.WriteHeader(http.StatusOK)
	if err := json.NewEncoder(w).Encode(map[string]string{"message": "Chave válida"}); err != nil {
		log.Printf("Erro ao escrever resposta de validação: %v", err)
	}
}

// createKeyHandler cria uma nova chave de API
func (a *App) createKeyHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Método não permitido", http.StatusMethodNotAllowed)
		return
	}

	var req CreateKeyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Corpo da requisição inválido", http.StatusBadRequest)
		return
	}

	if req.Name == "" {
		http.Error(w, "O campo 'name' é obrigatório", http.StatusBadRequest)
		return
	}

	// Gera uma nova chave e seu hash
	newKey, err := generateAPIKey()
	if err != nil {
		http.Error(w, "Erro ao gerar a chave", http.StatusInternalServerError)
		return
	}
	newKeyHash := hashAPIKey(newKey)

	// Salva o hash no banco de dados
	var newID int
	err = a.DB.QueryRow(
		"INSERT INTO api_keys (name, key_hash) VALUES ($1, $2) RETURNING id",
		req.Name, newKeyHash,
	).Scan(&newID)

	if err != nil {
		log.Printf("Erro ao salvar a chave no banco: %v", err)
		http.Error(w, "Erro ao salvar a chave", http.StatusInternalServerError)
		return
	}

	log.Printf("Nova chave criada com sucesso (ID: %d, Name: %s)", newID, req.Name)
	w.WriteHeader(http.StatusCreated)
	if err := json.NewEncoder(w).Encode(CreateKeyResponse{
		Name:    req.Name,
		Key:     newKey, // Retorna a chave em texto plano pela última vez
		Message: "Guarde esta chave com segurança! Você não poderá vê-la novamente.",
	}); err != nil {
		log.Printf("Erro ao escrever resposta de criação de chave: %v", err)
	}
}

// chaosHandler liga/desliga a falha injetada: POST /admin/chaos {"enabled": true|false}
// (protegido pelo masterKeyAuthMiddleware; registrado só com ENABLE_CHAOS=true)
func (a *App) chaosHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Método não permitido", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Enabled bool `json:"enabled"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Corpo da requisição inválido", http.StatusBadRequest)
		return
	}

	chaosEnabled.Store(req.Enabled)
	log.Printf("Chaos alterado: enabled=%t", req.Enabled)
	if err := json.NewEncoder(w).Encode(map[string]bool{"chaos": req.Enabled}); err != nil {
		log.Printf("Erro ao escrever resposta do chaos: %v", err)
	}
}

// --- Middleware ---

// masterKeyAuthMiddleware protege endpoints que só podem ser acessados com a MASTER_KEY
func (a *App) masterKeyAuthMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authHeader := r.Header.Get("Authorization")
		keyString := strings.TrimPrefix(authHeader, "Bearer ")

		if keyString != a.MasterKey {
			http.Error(w, "Acesso não autorizado", http.StatusForbidden)
			return
		}
		// Se a chave for válida, continua para o handler principal
		next.ServeHTTP(w, r)
	})
}