# Estágio 1: Builder
FROM golang:1.26-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
COPY . .
RUN go mod download
RUN go build -o auth-api .

# Estágio 2: Produção (Imagem limpa e leve)
FROM alpine:latest
WORKDIR /app
COPY --from=builder /app/auth-api .
EXPOSE 8001
CMD ["./auth-api"]