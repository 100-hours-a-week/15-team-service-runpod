#!/usr/bin/env bash
set -euo pipefail

ALLOY_METRICS_TEMPLATE_PATH="/src/alloy/metrics.river.tmpl"
ALLOY_LOGS_TEMPLATE_PATH="/src/alloy/logs.river.tmpl"
ALLOY_CONFIG_PATH="/tmp/alloy-observability.river"
ALLOY_PID=""
WORKER_PID=""
INACTIVE_OTLP_ENDPOINT="http://127.0.0.1:4318"

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

normalize_otlp_compression() {
  local value="$1"
  local name="$2"
  case "${value}" in
    gzip|none)
      echo "${value}"
      ;;
    *)
      log "Invalid ${name}='${value}', defaulting to 'gzip'."
      echo "gzip"
      ;;
  esac
}

render_metrics_alloy_config() {
  local metrics_active="$1"
  local metrics_endpoint="$2"

  local scrape_target="${METRICS_SCRAPE_TARGET:-127.0.0.1:8000}"
  local scrape_path="${METRICS_SCRAPE_PATH:-/metrics}"
  local scrape_interval="${METRICS_SCRAPE_INTERVAL:-15s}"
  local scrape_timeout="${METRICS_SCRAPE_TIMEOUT:-5s}"
  local pipeline_name="${METRICS_PIPELINE_NAME:-vllm}"
  local metrics_otlp_timeout="${METRICS_OTLP_TIMEOUT:-10s}"
  local metrics_otlp_compression="${METRICS_OTLP_COMPRESSION:-gzip}"
  local metrics_otlp_insecure
  local metrics_otlp_insecure_skip_verify
  local metrics_forward_to

  metrics_otlp_insecure="$(to_river_bool "${METRICS_OTLP_INSECURE:-false}")"
  metrics_otlp_insecure_skip_verify="$(to_river_bool "${METRICS_OTLP_INSECURE_SKIP_VERIFY:-false}")"

  metrics_otlp_compression="$(normalize_otlp_compression "${metrics_otlp_compression}" "METRICS_OTLP_COMPRESSION")"

  if [[ "${metrics_active}" == "true" ]]; then
    metrics_forward_to="[otelcol.receiver.prometheus.vllm.receiver]"
  else
    metrics_forward_to="[]"
    metrics_endpoint="${INACTIVE_OTLP_ENDPOINT}"
  fi

  sed \
    -e "s|__METRICS_SCRAPE_TARGET__|$(escape_sed "${scrape_target}")|g" \
    -e "s|__METRICS_SCRAPE_PATH__|$(escape_sed "${scrape_path}")|g" \
    -e "s|__METRICS_SCRAPE_INTERVAL__|$(escape_sed "${scrape_interval}")|g" \
    -e "s|__METRICS_SCRAPE_TIMEOUT__|$(escape_sed "${scrape_timeout}")|g" \
    -e "s|__METRICS_FORWARD_TO__|$(escape_sed "${metrics_forward_to}")|g" \
    -e "s|__METRICS_OTLP_HTTP_ENDPOINT__|$(escape_sed "${metrics_endpoint}")|g" \
    -e "s|__METRICS_OTLP_TIMEOUT__|$(escape_sed "${metrics_otlp_timeout}")|g" \
    -e "s|__METRICS_OTLP_COMPRESSION__|$(escape_sed "${metrics_otlp_compression}")|g" \
    -e "s|__METRICS_PIPELINE_NAME__|$(escape_sed "${pipeline_name}")|g" \
    -e "s|__METRICS_OTLP_INSECURE__|${metrics_otlp_insecure}|g" \
    -e "s|__METRICS_OTLP_INSECURE_SKIP_VERIFY__|${metrics_otlp_insecure_skip_verify}|g" \
    "${ALLOY_METRICS_TEMPLATE_PATH}" > "${ALLOY_CONFIG_PATH}"
}

append_logs_alloy_config() {
  local logs_endpoint="$1"
  local logs_file_path="${LOGS_FILE_PATH:-/tmp/worker.log}"
  local logs_otlp_timeout="${LOGS_OTLP_TIMEOUT:-10s}"
  local logs_otlp_compression="${LOGS_OTLP_COMPRESSION:-gzip}"
  local logs_otlp_insecure
  local logs_otlp_insecure_skip_verify

  if [[ ! -f "${ALLOY_LOGS_TEMPLATE_PATH}" ]]; then
    log "Alloy logs template not found at ${ALLOY_LOGS_TEMPLATE_PATH}."
    return 1
  fi

  logs_otlp_insecure="$(to_river_bool "${LOGS_OTLP_INSECURE:-false}")"
  logs_otlp_insecure_skip_verify="$(to_river_bool "${LOGS_OTLP_INSECURE_SKIP_VERIFY:-false}")"
  logs_otlp_compression="$(normalize_otlp_compression "${logs_otlp_compression}" "LOGS_OTLP_COMPRESSION")"

  {
    printf "\n"
    sed \
      -e "s|__LOGS_FILE_INCLUDE__|[\"$(escape_sed "${logs_file_path}")\"]|g" \
      -e "s|__LOGS_OTLP_HTTP_ENDPOINT__|$(escape_sed "${logs_endpoint}")|g" \
      -e "s|__LOGS_OTLP_TIMEOUT__|$(escape_sed "${logs_otlp_timeout}")|g" \
      -e "s|__LOGS_OTLP_COMPRESSION__|$(escape_sed "${logs_otlp_compression}")|g" \
      -e "s|__LOGS_OTLP_INSECURE__|${logs_otlp_insecure}|g" \
      -e "s|__LOGS_OTLP_INSECURE_SKIP_VERIFY__|${logs_otlp_insecure_skip_verify}|g" \
      "${ALLOY_LOGS_TEMPLATE_PATH}"
  } >> "${ALLOY_CONFIG_PATH}"
}

start_alloy_process() {
  local use_preview="$1"
  if [[ "${use_preview}" == "true" ]]; then
    alloy run --stability.level=public-preview "${ALLOY_CONFIG_PATH}" &
  else
    alloy run "${ALLOY_CONFIG_PATH}" &
  fi
  ALLOY_PID=$!

  # If Alloy exits immediately (invalid config/component), continue serving.
  sleep 1
  if ! kill -0 "${ALLOY_PID}" 2>/dev/null; then
    wait "${ALLOY_PID}" 2>/dev/null || true
    ALLOY_PID=""
    return 1
  fi
  return 0
}

start_alloy_if_enabled() {
  local metrics_enabled
  local logs_enabled
  local preview_logs_enabled
  local metrics_endpoint
  local logs_endpoint
  local metrics_active="false"
  local logs_active="false"

  metrics_enabled="$(to_river_bool "${METRICS_EXPORT_ENABLED:-true}")"
  logs_enabled="$(to_river_bool "${LOGS_EXPORT_ENABLED:-false}")"
  preview_logs_enabled="$(to_river_bool "${ALLOY_ENABLE_PREVIEW_LOGS:-false}")"

  metrics_endpoint="${METRICS_OTLP_HTTP_ENDPOINT:-}"
  logs_endpoint="${LOGS_OTLP_HTTP_ENDPOINT:-}"

  if [[ -z "${logs_endpoint}" ]]; then
    logs_endpoint="${metrics_endpoint}"
  fi

  if [[ ! -f "${ALLOY_METRICS_TEMPLATE_PATH}" ]]; then
    log "Alloy template not found at ${ALLOY_METRICS_TEMPLATE_PATH}. Starting worker without Alloy."
    return
  fi

  if ! command -v alloy >/dev/null 2>&1; then
    log "Alloy binary is not available. Starting worker without Alloy."
    return
  fi

  if [[ "${metrics_enabled}" == "true" ]]; then
    if [[ -n "${metrics_endpoint}" ]]; then
      metrics_active="true"
    else
      log "METRICS_OTLP_HTTP_ENDPOINT is empty. Metrics export disabled; worker will continue."
    fi
  else
    log "METRICS_EXPORT_ENABLED is false. Metrics export disabled."
  fi

  if [[ "${logs_enabled}" == "true" ]]; then
    if [[ "${preview_logs_enabled}" != "true" ]]; then
      log "LOGS_EXPORT_ENABLED is true but ALLOY_ENABLE_PREVIEW_LOGS is false. Logs export disabled; worker will continue."
    elif [[ -n "${logs_endpoint}" ]]; then
      logs_active="true"
    else
      log "LOGS_OTLP_HTTP_ENDPOINT and METRICS_OTLP_HTTP_ENDPOINT are empty. Logs export disabled; worker will continue."
    fi
  else
    log "LOGS_EXPORT_ENABLED is false. Logs export disabled."
  fi

  if [[ "${metrics_active}" != "true" && "${logs_active}" != "true" ]]; then
    log "No active OTLP signal pipelines. Starting worker without Alloy."
    return
  fi

  render_metrics_alloy_config "${metrics_active}" "${metrics_endpoint}"

  if [[ "${logs_active}" == "true" ]]; then
    if append_logs_alloy_config "${logs_endpoint}" && start_alloy_process "true"; then
      log "Started Alloy observability pipeline (pid=${ALLOY_PID}) metrics=${metrics_active} logs=${logs_active} using ${ALLOY_CONFIG_PATH}."
      return
    fi
    log "Alloy failed to start with preview logs. Falling back to metrics-only pipeline."
    logs_active="false"
    render_metrics_alloy_config "${metrics_active}" "${metrics_endpoint}"
  fi

  if start_alloy_process "false"; then
    log "Started Alloy observability pipeline (pid=${ALLOY_PID}) metrics=${metrics_active} logs=${logs_active} using ${ALLOY_CONFIG_PATH}."
  else
    log "Alloy failed to start. Continuing without Alloy; worker will continue."
  fi
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
