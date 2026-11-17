package main

import (
	"context"
	"encoding/json"
	"log"
	"path"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/service/sqs"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/trace"
)

// Evento que será enviado para a fila
type EvaluationEvent struct {
	UserID    string    `json:"user_id"`
	FlagName  string    `json:"flag_name"`
	Result    bool      `json:"result"`
	Timestamp time.Time `json:"timestamp"`
}

// sqsCarrier adapta os MessageAttributes do SQS para a propagação de contexto do OpenTelemetry.
// O traceparent viaja na mensagem e o analytics-service continua o mesmo trace do outro lado da fila.
type sqsCarrier map[string]*sqs.MessageAttributeValue

func (c sqsCarrier) Get(key string) string {
	if v, ok := c[key]; ok && v != nil && v.StringValue != nil {
		return *v.StringValue
	}
	return ""
}

func (c sqsCarrier) Set(key, value string) {
	c[key] = &sqs.MessageAttributeValue{
		DataType:    aws.String("String"),
		StringValue: aws.String(value),
	}
}

func (c sqsCarrier) Keys() []string {
	keys := make([]string, 0, len(c))
	for k := range c {
		keys = append(keys, k)
	}
	return keys
}

// sendEvaluationEvent envia um evento para a fila SQS.
// O ctx deve carregar o span da requisição (sem o cancelamento dela), ver handlers.go.
func (a *App) sendEvaluationEvent(ctx context.Context, userID, flagName string, result bool) {
	// Se a URL da fila não foi configurada, apenas loga localmente e sai.
	if a.SqsSvc == nil || a.SqsQueueURL == "" {
		log.Printf("[SQS_DISABLED] Evento: User '%s', Flag '%s', Result '%t'", userID, flagName, result)
		return
	}

	ctx, span := tracer.Start(ctx, "SQS publish",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String("messaging.system", "aws_sqs"),
			attribute.String("messaging.destination.name", path.Base(a.SqsQueueURL)),
			attribute.String("messaging.operation", "publish"),
		),
	)
	defer span.End()

	event := EvaluationEvent{
		UserID:    userID,
		FlagName:  flagName,
		Result:    result,
		Timestamp: time.Now().UTC(),
	}

	body, err := json.Marshal(event)
	if err != nil {
		log.Printf("Erro ao serializar evento SQS: %v", err)
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return
	}

	// Injeta o traceparent nos atributos da mensagem
	carrier := sqsCarrier{}
	otel.GetTextMapPropagator().Inject(ctx, carrier)

	// Envia a mensagem
	_, err = a.SqsSvc.SendMessageWithContext(ctx, &sqs.SendMessageInput{
		MessageBody:       aws.String(string(body)),
		QueueUrl:          aws.String(a.SqsQueueURL),
		MessageAttributes: carrier,
	})

	if err != nil {
		log.Printf("Erro ao enviar mensagem para SQS: %v", err)
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		eventsSent.Add(ctx, 1, metric.WithAttributes(attribute.String("status", "error")))
		return
	}

	log.Printf("Evento de avaliação enviado para SQS (Flag: %s)", flagName)
	eventsSent.Add(ctx, 1, metric.WithAttributes(attribute.String("status", "ok")))
}
