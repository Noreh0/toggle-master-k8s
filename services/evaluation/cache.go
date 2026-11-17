package main

import (
	"context"
	"errors"
	"time"

	"github.com/go-redis/redis/v8"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

// redisGet lê uma chave do Redis dentro de um span (db.system=redis), para o Redis
// aparecer no trace e no Service Map. Redis Nil (cache miss) não é tratado como erro.
func (a *App) redisGet(ctx context.Context, key string) (string, error) {
	ctx, span := tracer.Start(ctx, "redis GET",
		trace.WithSpanKind(trace.SpanKindClient),
		trace.WithAttributes(
			attribute.String("db.system", "redis"),
			attribute.String("db.operation", "GET"),
		),
	)
	defer span.End()

	val, err := a.RedisClient.Get(ctx, key).Result()
	switch {
	case err == nil:
		span.SetAttributes(attribute.Bool("cache.hit", true))
	case errors.Is(err, redis.Nil):
		span.SetAttributes(attribute.Bool("cache.hit", false))
	default:
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
	}
	return val, err
}

// redisSet grava uma chave no Redis dentro de um span.
func (a *App) redisSet(ctx context.Context, key string, value interface{}, ttl time.Duration) error {
	ctx, span := tracer.Start(ctx, "redis SET",
		trace.WithSpanKind(trace.SpanKindClient),
		trace.WithAttributes(
			attribute.String("db.system", "redis"),
			attribute.String("db.operation", "SET"),
		),
	)
	defer span.End()

	err := a.RedisClient.Set(ctx, key, value, ttl).Err()
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
	}
	return err
}
