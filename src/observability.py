import logging
import os
import threading
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Type

try:
    from opentelemetry import metrics as otel_metrics
    from opentelemetry._logs import set_logger_provider
    from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
    from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
    from opentelemetry.metrics import Observation
    from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
    from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
    from opentelemetry.sdk.metrics import MeterProvider
    from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
    from opentelemetry.sdk.resources import Resource

    OTEL_AVAILABLE = True
except ImportError:
    OTEL_AVAILABLE = False

log = logging.getLogger("worker.observability")

TRUE_VALUES = {"1", "true", "yes", "on"}
_DEFAULT_INTERVAL_MS = 15000
_DEFAULT_SERVICE_NAME = "worker-vllm"


def _env_bool(name: str, default: bool) -> bool:
    return str(os.getenv(name, str(default))).strip().lower() in TRUE_VALUES


def _parse_headers(value: str) -> Dict[str, str]:
    headers: Dict[str, str] = {}
    if not value:
        return headers
    for raw_item in value.split(","):
        item = raw_item.strip()
        if not item or "=" not in item:
            continue
        key, val = item.split("=", 1)
        key = key.strip()
        val = val.strip()
        if key:
            headers[key] = val
    return headers


def _parse_duration_seconds(raw_value: Optional[str], default_seconds: float) -> float:
    if raw_value is None:
        return default_seconds
    value = raw_value.strip().lower()
    if not value:
        return default_seconds
    try:
        if value.endswith("ms"):
            return max(float(value[:-2]) / 1000.0, 0.001)
        if value.endswith("s"):
            return max(float(value[:-1]), 0.001)
        if value.endswith("m"):
            return max(float(value[:-1]) * 60.0, 0.001)
        return max(float(value), 0.001)
    except ValueError:
        return default_seconds


def _normalize_otlp_protocol() -> str:
    protocol = str(os.getenv("OTEL_EXPORTER_OTLP_PROTOCOL", "http/protobuf")).strip().lower()
    if protocol and protocol != "http/protobuf":
        log.warning(
            "Unsupported OTLP protocol '%s'. This worker supports only 'http/protobuf'. Export disabled.",
            protocol,
        )
        return ""
    return "http/protobuf"


def _build_signal_endpoint(signal: str) -> Optional[str]:
    signal_env = os.getenv(f"OTEL_EXPORTER_OTLP_{signal.upper()}_ENDPOINT")
    if signal_env:
        return signal_env.strip()

    base = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
    if not base:
        return None
    base = base.strip().rstrip("/")
    return f"{base}/v1/{signal}"


def _build_otlp_exporter_kwargs(signal: str) -> Optional[Dict[str, object]]:
    protocol = _normalize_otlp_protocol()
    if not protocol:
        return None

    endpoint = _build_signal_endpoint(signal)
    if not endpoint:
        return None

    compression_raw = str(os.getenv("OTEL_EXPORTER_OTLP_COMPRESSION", "gzip")).strip().lower()
    if compression_raw not in {"gzip", "none"}:
        log.warning("Invalid OTLP compression '%s'; falling back to 'gzip'.", compression_raw)
        compression_raw = "gzip"
    compression = _resolve_otlp_compression(compression_raw, signal)

    timeout_seconds = _parse_duration_seconds(os.getenv("OTEL_EXPORTER_OTLP_TIMEOUT"), 10.0)
    headers = _parse_headers(os.getenv("OTEL_EXPORTER_OTLP_HEADERS", ""))

    return {
        "endpoint": endpoint,
        "headers": headers,
        "timeout": timeout_seconds,
        "compression": compression,
    }


def _build_resource() -> "Resource":
    service_name = str(os.getenv("OTEL_SERVICE_NAME", _DEFAULT_SERVICE_NAME)).strip() or _DEFAULT_SERVICE_NAME
    attrs = {"service.name": service_name}

    raw_resource_attrs = os.getenv("OTEL_RESOURCE_ATTRIBUTES", "")
    for raw_item in raw_resource_attrs.split(","):
        item = raw_item.strip()
        if not item or "=" not in item:
            continue
        key, val = item.split("=", 1)
        key = key.strip()
        val = val.strip()
        if key:
            attrs[key] = val
    return Resource.create(attrs)


def _get_signal_compression_enum(signal: str) -> Optional[Type[object]]:
    enum_class = None
    if signal == "metrics":
        try:
            from opentelemetry.exporter.otlp.proto.http.metric_exporter import Compression as MetricCompression

            enum_class = MetricCompression
        except Exception:
            enum_class = None
    elif signal == "logs":
        try:
            from opentelemetry.exporter.otlp.proto.http._log_exporter import Compression as LogCompression

            enum_class = LogCompression
        except Exception:
            enum_class = None

    if enum_class is not None:
        return enum_class

    try:
        from opentelemetry.exporter.otlp.proto.http import Compression as BaseCompression

        return BaseCompression
    except Exception:
        return None


def _resolve_otlp_compression(compression_raw: str, signal: str):
    enum_class = _get_signal_compression_enum(signal)
    if enum_class is None:
        # Older/newer OTel variants may still accept raw strings.
        return compression_raw

    try:
        members = list(enum_class.__members__.values())  # type: ignore[attr-defined]
    except Exception:
        return compression_raw

    for member in members:
        name = str(getattr(member, "name", "")).lower()
        value = str(getattr(member, "value", "")).lower()

        if compression_raw in {name, value}:
            return member
        if compression_raw == "none" and ("none" in name or "no_compression" in name or "nocompression" in name):
            return member
        if compression_raw == "gzip" and "gzip" in name:
            return member

    return compression_raw


def setup_otel_logs_handler(resource: "Resource"):
    """Build OTLP logs exporter and attach a handler to the Python root logger."""
    log_exporter_kwargs = _build_otlp_exporter_kwargs("logs")
    if log_exporter_kwargs is None:
        log.warning("OTLP logs endpoint not configured; logs export disabled.")
        return None, None

    try:
        log_exporter = OTLPLogExporter(**log_exporter_kwargs)
        log_provider = LoggerProvider(resource=resource)
        log_provider.add_log_record_processor(BatchLogRecordProcessor(log_exporter))
        set_logger_provider(log_provider)
        otel_log_handler = LoggingHandler(level=logging.NOTSET, logger_provider=log_provider)
        logging.getLogger().addHandler(otel_log_handler)
        log.info("OTLP logs export enabled endpoint=%s", log_exporter_kwargs["endpoint"])
        return log_provider, otel_log_handler
    except Exception as exc:
        log.warning(
            "Failed to initialize OTLP logs exporter (%s: %s). Logs export disabled.",
            exc.__class__.__name__,
            exc,
        )
        return None, None


class VLLMPrometheusBridge:
    """Bridges vLLM Prometheus samples into OTel ObservableGauges."""

    def __init__(self, meter):
        self._meter = meter
        self._registry = None
        self._names: List[str] = []
        self._enabled = False
        self._init_registry()
        if self._registry is not None:
            self._discover_and_register()

    def _init_registry(self) -> None:
        try:
            from prometheus_client import REGISTRY

            self._registry = REGISTRY
        except Exception as exc:
            log.warning(
                "Prometheus registry unavailable; vLLM metrics bridge disabled (%s: %s).",
                exc.__class__.__name__,
                exc,
            )
            self._registry = None

    def _iter_samples(self) -> Iterable[tuple]:
        if self._registry is None:
            return []
        try:
            for metric_family in self._registry.collect():
                for sample in metric_family.samples:
                    name = str(sample.name)
                    if not name.startswith("vllm"):
                        continue
                    yield sample.name, sample.labels, sample.value
        except Exception as exc:
            log.warning(
                "Failed to collect Prometheus samples for vLLM bridge (%s: %s).",
                exc.__class__.__name__,
                exc,
            )
            return []

    def _discover_metric_names(self) -> List[str]:
        names = sorted({name for name, _, _ in self._iter_samples()})
        if not names:
            log.warning("No vLLM Prometheus samples discovered; bridge registered no instruments.")
        return names

    def _callback_for_name(self, metric_name: str):
        def _callback(_options):
            observations: List[Observation] = []
            for name, labels, value in self._iter_samples():
                if name != metric_name:
                    continue
                attributes = {str(k): str(v) for k, v in labels.items()}
                try:
                    observations.append(Observation(float(value), attributes=attributes))
                except Exception:
                    continue
            return observations

        return _callback

    def _discover_and_register(self) -> None:
        try:
            self._names = self._discover_metric_names()
            for metric_name in self._names:
                self._meter.create_observable_gauge(
                    name=metric_name,
                    callbacks=[self._callback_for_name(metric_name)],
                    description="Bridged from vLLM Prometheus registry",
                )
            self._enabled = bool(self._names)
            if self._enabled:
                log.info("Registered %d vLLM Prometheus bridge gauges.", len(self._names))
        except Exception as exc:
            self._enabled = False
            log.warning(
                "Failed to initialize vLLM Prometheus bridge; continuing with worker metrics only (%s: %s).",
                exc.__class__.__name__,
                exc,
            )


@dataclass
class WorkerMetrics:
    enabled: bool = False
    _requests_total: Optional[object] = None
    _requests_failed_total: Optional[object] = None
    _request_latency_seconds: Optional[object] = None
    _active_requests: Optional[object] = None
    _input_tokens_total: Optional[object] = None
    _output_tokens_total: Optional[object] = None

    def on_request_started(self, route: str) -> None:
        if not self.enabled:
            return
        attrs = {"route": route}
        self._requests_total.add(1, attrs)
        self._active_requests.add(1, attrs)

    def on_request_finished(self, route: str, latency_seconds: float) -> None:
        if not self.enabled:
            return
        attrs = {"route": route}
        self._active_requests.add(-1, attrs)
        self._request_latency_seconds.record(max(latency_seconds, 0.0), attrs)

    def on_request_failed(self, route: str) -> None:
        if not self.enabled:
            return
        attrs = {"route": route}
        self._requests_failed_total.add(1, attrs)

    def on_tokens(self, route: str, input_tokens: int, output_tokens: int) -> None:
        if not self.enabled:
            return
        attrs = {"route": route}
        if input_tokens > 0:
            self._input_tokens_total.add(input_tokens, attrs)
        if output_tokens > 0:
            self._output_tokens_total.add(output_tokens, attrs)


class ObservabilityRuntime:
    def __init__(self) -> None:
        self.metrics = WorkerMetrics(enabled=False)
        self._meter_provider = None
        self._log_provider = None
        self._otel_log_handler = None
        self._bridge = None

    def setup(self) -> None:
        if not OTEL_AVAILABLE:
            log.warning("OpenTelemetry packages are not installed; direct OTLP observability disabled.")
            return

        metric_export_enabled = _env_bool("OTEL_METRICS_EXPORT_ENABLED", True)
        log_export_enabled = _env_bool("OTEL_LOGS_EXPORT_ENABLED", True)
        resource = _build_resource()

        if metric_export_enabled:
            self._setup_metrics(resource)
        else:
            log.info("OTEL_METRICS_EXPORT_ENABLED=false; metrics export disabled.")

        if log_export_enabled:
            self._setup_logs(resource)
        else:
            log.info("OTEL_LOGS_EXPORT_ENABLED=false; logs export disabled.")

    def _setup_metrics(self, resource: "Resource") -> None:
        metric_exporter_kwargs = _build_otlp_exporter_kwargs("metrics")
        if metric_exporter_kwargs is None:
            log.warning("OTLP metrics endpoint not configured; metrics export disabled.")
            return

        try:
            interval_ms = int(os.getenv("OTEL_METRIC_EXPORT_INTERVAL", str(_DEFAULT_INTERVAL_MS)))
        except ValueError:
            interval_ms = _DEFAULT_INTERVAL_MS
        if interval_ms < 1000:
            interval_ms = _DEFAULT_INTERVAL_MS

        metric_exporter = OTLPMetricExporter(**metric_exporter_kwargs)
        reader = PeriodicExportingMetricReader(metric_exporter, export_interval_millis=interval_ms)
        self._meter_provider = MeterProvider(metric_readers=[reader], resource=resource)
        otel_metrics.set_meter_provider(self._meter_provider)
        meter = otel_metrics.get_meter("worker-vllm.observability")

        self.metrics = WorkerMetrics(
            enabled=True,
            _requests_total=meter.create_counter("worker.requests_total"),
            _requests_failed_total=meter.create_counter("worker.requests_failed_total"),
            _request_latency_seconds=meter.create_histogram("worker.request_latency_seconds", unit="s"),
            _active_requests=meter.create_up_down_counter("worker.active_requests"),
            _input_tokens_total=meter.create_counter("worker.input_tokens_total"),
            _output_tokens_total=meter.create_counter("worker.output_tokens_total"),
        )

        self._bridge = VLLMPrometheusBridge(meter)
        log.info(
            "OTLP metrics export enabled endpoint=%s interval_ms=%s",
            metric_exporter_kwargs["endpoint"],
            interval_ms,
        )

    def _setup_logs(self, resource: "Resource") -> None:
        self._log_provider, self._otel_log_handler = setup_otel_logs_handler(resource)

    def shutdown(self) -> None:
        if self._otel_log_handler is not None:
            root_logger = logging.getLogger()
            root_logger.removeHandler(self._otel_log_handler)
            self._otel_log_handler = None

        if self._log_provider is not None:
            try:
                self._log_provider.shutdown()
            except Exception:
                pass
            self._log_provider = None

        if self._meter_provider is not None:
            try:
                self._meter_provider.shutdown()
            except Exception:
                pass
            self._meter_provider = None


_runtime_lock = threading.Lock()
_runtime: Optional[ObservabilityRuntime] = None


def setup_observability() -> WorkerMetrics:
    global _runtime
    with _runtime_lock:
        if _runtime is None:
            _runtime = ObservabilityRuntime()
            _runtime.setup()
        return _runtime.metrics


def get_worker_metrics() -> WorkerMetrics:
    if _runtime is None:
        return WorkerMetrics(enabled=False)
    return _runtime.metrics


def shutdown_observability() -> None:
    global _runtime
    with _runtime_lock:
        if _runtime is not None:
            _runtime.shutdown()
            _runtime = None
