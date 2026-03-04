#!/usr/bin/env bash
set -euo pipefail

ALLOY_TEMPLATE_PATH="/src/alloy/metrics.river.tmpl"
ALLOY_CONFIG_PATH="/tmp/alloy-metrics.river"
ALLOY_PID=""
WORKER_PID=""

log() {
  echo "[entrypoint] $*"
}

to_river_bool() {
  local value
  value="$(echo "${1:-false}" | tr '[:upper:]' '[:lower:]')"
  case "${value}" in
    1|true|yes|on) echo "true" ;;
    *) echo "false" ;;
  esac
}

escape_sed() {
  printf "%s" "$1" | sed -e 's/[\/&]/\\&/g'
}

render_alloy_config() {
  local scrape_target="${METRICS_SCRAPE_TARGET:-127.0.0.1:8000}"
  local scrape_path="${METRICS_SCRAPE_PATH:-/metrics}"
  local scrape_interval="${METRICS_SCRAPE_INTERVAL:-15s}"
  local scrape_timeout="${METRICS_SCRAPE_TIMEOUT:-5s}"
  local otlp_endpoint="${METRICS_OTLP_HTTP_ENDPOINT:-}"
  local otlp_timeout="${METRICS_OTLP_TIMEOUT:-10s}"
  local otlp_compression="${METRICS_OTLP_COMPRESSION:-gzip}"
  local pipeline_name="${METRICS_PIPELINE_NAME:-vllm}"
  local otlp_insecure
  local otlp_insecure_skip_verify

  otlp_insecure="$(to_river_bool "${METRICS_OTLP_INSECURE:-false}")"
  otlp_insecure_skip_verify="$(to_river_bool "${METRICS_OTLP_INSECURE_SKIP_VERIFY:-false}")"

  case "${otlp_compression}" in
    gzip|none) ;;
    *)
      log "Invalid METRICS_OTLP_COMPRESSION='${otlp_compression}', defaulting to 'gzip'."
      otlp_compression="gzip"
      ;;
  esac

  sed \
    -e "s|__METRICS_SCRAPE_TARGET__|$(escape_sed "${scrape_target}")|g" \
    -e "s|__METRICS_SCRAPE_PATH__|$(escape_sed "${scrape_path}")|g" \
    -e "s|__METRICS_SCRAPE_INTERVAL__|$(escape_sed "${scrape_interval}")|g" \
    -e "s|__METRICS_SCRAPE_TIMEOUT__|$(escape_sed "${scrape_timeout}")|g" \
    -e "s|__METRICS_OTLP_HTTP_ENDPOINT__|$(escape_sed "${otlp_endpoint}")|g" \
    -e "s|__METRICS_OTLP_TIMEOUT__|$(escape_sed "${otlp_timeout}")|g" \
    -e "s|__METRICS_OTLP_COMPRESSION__|$(escape_sed "${otlp_compression}")|g" \
    -e "s|__METRICS_PIPELINE_NAME__|$(escape_sed "${pipeline_name}")|g" \
    -e "s|__METRICS_OTLP_INSECURE__|${otlp_insecure}|g" \
    -e "s|__METRICS_OTLP_INSECURE_SKIP_VERIFY__|${otlp_insecure_skip_verify}|g" \
    "${ALLOY_TEMPLATE_PATH}" > "${ALLOY_CONFIG_PATH}"
}

start_alloy_if_enabled() {
  local metrics_enabled
  metrics_enabled="$(to_river_bool "${METRICS_EXPORT_ENABLED:-true}")"

  if [[ "${metrics_enabled}" != "true" ]]; then
    log "METRICS_EXPORT_ENABLED is false. Starting worker without Alloy."
    return
  fi

  if [[ -z "${METRICS_OTLP_HTTP_ENDPOINT:-}" ]]; then
    log "METRICS_OTLP_HTTP_ENDPOINT is empty. Metrics export disabled; worker will continue."
    return
  fi

  if [[ ! -f "${ALLOY_TEMPLATE_PATH}" ]]; then
    log "Alloy template not found at ${ALLOY_TEMPLATE_PATH}. Starting worker without Alloy."
    return
  fi

  if ! command -v alloy >/dev/null 2>&1; then
    log "Alloy binary is not available. Starting worker without Alloy."
    return
  fi

  render_alloy_config
  alloy run "${ALLOY_CONFIG_PATH}" &
  ALLOY_PID=$!
  log "Started Alloy metrics pipeline (pid=${ALLOY_PID}) using ${ALLOY_CONFIG_PATH}."
}

stop_alloy() {
  if [[ -n "${ALLOY_PID}" ]] && kill -0 "${ALLOY_PID}" 2>/dev/null; then
    log "Stopping Alloy (pid=${ALLOY_PID})."
    kill -TERM "${ALLOY_PID}" 2>/dev/null || true
    wait "${ALLOY_PID}" 2>/dev/null || true
  fi
}

on_signal() {
  local signal_name="$1"
  log "Received ${signal_name}. Shutting down worker and Alloy."
  if [[ -n "${WORKER_PID}" ]] && kill -0 "${WORKER_PID}" 2>/dev/null; then
    kill -TERM "${WORKER_PID}" 2>/dev/null || true
  fi
  stop_alloy
}

trap 'on_signal SIGTERM' SIGTERM
trap 'on_signal SIGINT' SIGINT

start_alloy_if_enabled

python3 /src/handler.py &
WORKER_PID=$!

set +e
wait "${WORKER_PID}"
WORKER_EXIT_CODE=$?
set -e

stop_alloy
exit "${WORKER_EXIT_CODE}"
