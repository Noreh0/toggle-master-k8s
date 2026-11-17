"""OpenTelemetry: traces e métricas via OTLP/HTTP para o OTel Collector.

- Só é ativado se OTEL_EXPORTER_OTLP_ENDPOINT estiver definida (dev local fica sem telemetria).
- Nome do serviço e atributos vêm de OTEL_SERVICE_NAME e OTEL_RESOURCE_ATTRIBUTES.
- Deve rodar no processo que atende as requisições. O gunicorn, sem --preload, importa o app
  dentro do worker (depois do fork), então as threads do exporter sobrevivem.
"""
import os

_BASE_FORMAT = "%(asctime)s %(levelname)s [%(name)s] %(message)s"
_TRACE_FORMAT = (
    "%(asctime)s %(levelname)s [%(name)s] "
    "[trace_id=%(otelTraceID)s span_id=%(otelSpanID)s] %(message)s"
)

_enabled = False


def telemetry_enabled():
    return bool(os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"))


def init_telemetry():
    """Configura tracer/meter providers e instrumenta as bibliotecas presentes no serviço."""
    global _enabled
    if _enabled or not telemetry_enabled():
        return _enabled

    from opentelemetry import metrics, trace
    from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.instrumentation.logging import LoggingInstrumentor
    from opentelemetry.sdk.metrics import MeterProvider
    from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    resource = Resource.create()  # lê OTEL_SERVICE_NAME e OTEL_RESOURCE_ATTRIBUTES

    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(tracer_provider)

    reader = PeriodicExportingMetricReader(OTLPMetricExporter(), export_interval_millis=15000)
    metrics.set_meter_provider(MeterProvider(resource=resource, metric_readers=[reader]))

    # Acrescenta trace_id/span_id aos registros de log (o formato é definido em log_format())
    LoggingInstrumentor().instrument(set_logging_format=False)

    # Bibliotecas de saída: o que existir no serviço é instrumentado
    try:
        from opentelemetry.instrumentation.requests import RequestsInstrumentor
        RequestsInstrumentor().instrument()
    except ImportError:
        pass
    try:
        from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor
        Psycopg2Instrumentor().instrument()
    except ImportError:
        pass
    try:
        from opentelemetry.instrumentation.botocore import BotocoreInstrumentor
        BotocoreInstrumentor().instrument()
    except ImportError:
        pass

    _enabled = True
    return True


def instrument_flask(app):
    """Instrumenta o app Flask: um span por requisição e métricas http.server.*."""
    if not _enabled:
        return
    from opentelemetry.instrumentation.flask import FlaskInstrumentor
    FlaskInstrumentor().instrument_app(app)


def log_format():
    """Formato de log: com trace_id/span_id só quando a telemetria está ativa."""
    return _TRACE_FORMAT if _enabled else _BASE_FORMAT
