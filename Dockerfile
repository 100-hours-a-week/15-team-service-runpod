FROM nvidia/cuda:12.4.1-base-ubuntu22.04 
ARG ALLOY_VERSION=1.13.2

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends python3-pip curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG TARGETARCH
RUN apt-get update -y \
    && case "${TARGETARCH}" in \
        amd64|arm64) ALLOY_DEB_ARCH="${TARGETARCH}" ;; \
        *) echo "Unsupported TARGETARCH for Alloy package: ${TARGETARCH}" && exit 1 ;; \
       esac \
    && curl -fL "https://github.com/grafana/alloy/releases/download/v${ALLOY_VERSION}/alloy-${ALLOY_VERSION}-1.${ALLOY_DEB_ARCH}.deb" -o /tmp/alloy.deb \
    && apt-get install -y --no-install-recommends /tmp/alloy.deb \
    && rm -f /tmp/alloy.deb \
    && rm -rf /var/lib/apt/lists/*

RUN ldconfig /usr/local/cuda-12.4/compat/

# Install vLLM with FlashInfer - use CUDA 12.4 PyTorch wheels (compatible with vLLM 0.15.0)
RUN python3 -m pip install --upgrade pip && \
    python3 -m pip install "vllm[flashinfer]==0.15.0" --extra-index-url https://download.pytorch.org/whl/cu124



# Install additional Python dependencies (after vLLM to avoid PyTorch version conflicts)
COPY builder/requirements.txt /requirements.txt
RUN --mount=type=cache,target=/root/.cache/pip \
    python3 -m pip install --upgrade -r /requirements.txt && \
    python3 -m pip check

# Setup for Option 2: Building the Image with the Model included
ARG MODEL_NAME=""
ARG TOKENIZER_NAME=""
ARG BASE_PATH="/runpod-volume"
ARG QUANTIZATION=""
ARG MODEL_REVISION=""
ARG TOKENIZER_REVISION=""
ARG VLLM_NIGHTLY="false"

ENV MODEL_NAME=$MODEL_NAME \
    MODEL_REVISION=$MODEL_REVISION \
    TOKENIZER_NAME=$TOKENIZER_NAME \
    TOKENIZER_REVISION=$TOKENIZER_REVISION \
    BASE_PATH=$BASE_PATH \
    QUANTIZATION=$QUANTIZATION \
    HF_DATASETS_CACHE="${BASE_PATH}/huggingface-cache/datasets" \
    HUGGINGFACE_HUB_CACHE="${BASE_PATH}/huggingface-cache/hub" \
    HF_HOME="${BASE_PATH}/huggingface-cache/hub" \
    HF_HUB_ENABLE_HF_TRANSFER=0 \
    # Suppress Ray metrics agent warnings (not needed in containerized environments)
    RAY_METRICS_EXPORT_ENABLED=0 \
    RAY_DISABLE_USAGE_STATS=1 \
    # Prevent rayon thread pool panic in containers where ulimit -u < nproc
    # (tokenizers uses Rust's rayon which tries to spawn threads = CPU cores)
    TOKENIZERS_PARALLELISM=false \
    RAYON_NUM_THREADS=4 \
    METRICS_EXPORT_ENABLED=true \
    METRICS_SCRAPE_TARGET=127.0.0.1:8000 \
    METRICS_SCRAPE_PATH=/metrics \
    METRICS_SCRAPE_INTERVAL=15s \
    METRICS_SCRAPE_TIMEOUT=5s \
    METRICS_OTLP_HTTP_ENDPOINT= \
    METRICS_OTLP_INSECURE=false \
    METRICS_OTLP_INSECURE_SKIP_VERIFY=false \
    METRICS_OTLP_COMPRESSION=gzip \
    METRICS_OTLP_TIMEOUT=10s \
    METRICS_PIPELINE_NAME=vllm

ENV PYTHONPATH="/:/vllm-workspace"

RUN if [ "${VLLM_NIGHTLY}" = "true" ]; then \
    pip install -U vllm --pre --index-url https://pypi.org/simple --extra-index-url https://wheels.vllm.ai/nightly && \
    apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/* && \
    pip install git+https://github.com/huggingface/transformers.git; \
fi

COPY src /src
RUN chmod +x /src/entrypoint.sh
RUN --mount=type=secret,id=HF_TOKEN,required=false \
    if [ -f /run/secrets/HF_TOKEN ]; then \
    export HF_TOKEN=$(cat /run/secrets/HF_TOKEN); \
    fi && \
    if [ -n "$MODEL_NAME" ]; then \
    python3 /src/download_model.py; \
    fi

# Start the handler
CMD ["/src/entrypoint.sh"]
