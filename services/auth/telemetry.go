package main

import (
	"context"
	"log"
	"os"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

var tracer = otel.Tracer("auth-service")

// initTelemetry configura traces e métricas OpenTelemetry (OTLP/HTTP para o OTel Collector).
// O endpoint vem de OTEL_EXPORTER_OTLP_ENDPOINT e o nome do serviço de OTEL_SERVICE_NAME.
// Sem endpoint, a telemetria fica desligada (dev local). Sempre devolve uma função de shutdown segura.
func initTelemetry(ctx context.Context) (func(context.Context), error) {
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{},
	))

	noop := func(context.Context) {}
	if os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") == "" {
		log.Println("Telemetria OpenTelemetry desabilitada (OTEL_EXPORTER_OTLP_ENDPOINT não definida).")
		return noop, nil
	}

	res, err := resource.New(ctx,
		resource.WithFromEnv(),
		resource.WithTelemetrySDK(),
		resource.WithHost(),
	)
	if err != nil {
		return noop, err
	}

	traceExp, err := otlptracehttp.New(ctx)
	if err != nil {
		return noop, err
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExp),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)

	metricExp, err := otlpmetrichttp.New(ctx)
	if err != nil {
		_ = tp.Shutdown(ctx)
		return noop, err
	}
	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExp, sdkmetric.WithInterval(15*time.Second))),
		sdkmetric.WithResource(res),
	)
	otel.SetMeterProvider(mp)

	log.Println("Telemetria OpenTelemetry habilitada.")
	return func(c context.Context) {
		if err := tp.Shutdown(c); err != nil {
			log.Printf("Erro ao encerrar o tracer provider: %v", err)
		}
		if err := mp.Shutdown(c); err != nil {
			log.Printf("Erro ao encerrar o meter provider: %v", err)
		}
	}, nil
}
