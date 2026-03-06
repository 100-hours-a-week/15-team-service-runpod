import sys
import logging
import multiprocessing
import traceback
import time
import atexit
from logging_setup import configure_logging, get_bool_env

configure_logging()
log = logging.getLogger("worker")
import runpod
from observability import (
    get_worker_metrics,
    refresh_vllm_metrics_bridge,
    setup_observability,
    shutdown_observability,
)

vllm_engine = None
openai_engine = None
sensitive_text_logging = get_bool_env("LOGS_INCLUDE_PROMPT_TEXT", False) or get_bool_env("LOGS_INCLUDE_RESPONSE_TEXT", False)
worker_metrics = get_worker_metrics()


def _safe_error_message(exc: Exception) -> str:
    if sensitive_text_logging:
        return str(exc)
    return "<redacted>"


def _format_traceback(exc: Exception) -> str:
    if sensitive_text_logging:
        return traceback.format_exc()
    stack_only = "".join(traceback.format_tb(exc.__traceback__))
    return f"{stack_only}{exc.__class__.__name__}: <redacted>"


async def handler(job):
    request_id = "unknown"
    route = "vllm"
    started_at = time.time()
    input_tokens = 0
    output_tokens = 0
    request_started_recorded = False
    try:
        from utils import JobInput
        job_input = JobInput(job["input"])
        request_id = job_input.request_id
        route = job_input.openai_route or route
        refresh_vllm_metrics_bridge()
        worker_metrics.on_request_started(route=route)
        request_started_recorded = True
        log.info(
            "request started request_id=%s route=%s stream=%s",
            request_id,
            route,
            job_input.stream,
        )
        engine = openai_engine if job_input.openai_route else vllm_engine
        results_generator = engine.generate(job_input)
        async for batch in results_generator:
            if isinstance(batch, dict):
                usage = batch.get("usage")
                if isinstance(usage, dict):
                    try:
                        input_tokens = max(int(usage.get("input", input_tokens)), input_tokens)
                    except (TypeError, ValueError):
                        pass
                    try:
                        output_tokens = max(int(usage.get("output", output_tokens)), output_tokens)
                    except (TypeError, ValueError):
                        pass
            yield batch
        log.info(
            "request completed request_id=%s route=%s duration_s=%.3f",
            request_id,
            route,
            time.time() - started_at,
        )
    except Exception as e:
        error_str = str(e)
        safe_message = _safe_error_message(e)
        safe_traceback = _format_traceback(e)

        log.error(
            "request failed request_id=%s route=%s error_type=%s error=%s",
            request_id,
            route,
            e.__class__.__name__,
            safe_message,
        )
        log.error("request traceback request_id=%s\n%s", request_id, safe_traceback)
        worker_metrics.on_request_failed(route=route)

        # CUDA errors = worker is broken, exit to let RunPod spin up a healthy one
        if "CUDA" in error_str or "cuda" in error_str:
            log.error("terminating worker due to CUDA/GPU error request_id=%s", request_id)
            sys.exit(1)

        yield {"error": error_str}
    finally:
        refresh_vllm_metrics_bridge()
        if request_started_recorded:
            worker_metrics.on_request_finished(route=route, latency_seconds=time.time() - started_at)
        if input_tokens > 0 or output_tokens > 0:
            worker_metrics.on_tokens(route=route, input_tokens=input_tokens, output_tokens=output_tokens)


# Only run in main process to prevent re-initialization when vLLM spawns worker subprocesses
if __name__ == "__main__" or multiprocessing.current_process().name == "MainProcess":
    worker_metrics = setup_observability()
    atexit.register(shutdown_observability)

    try:
        from engine import vLLMEngine, OpenAIvLLMEngine

        vllm_engine = vLLMEngine()
        openai_engine = OpenAIvLLMEngine(vllm_engine)
        refresh_vllm_metrics_bridge()
        log.info("vLLM engines initialized successfully")
    except Exception as e:
        log.error("worker startup failed error_type=%s error=%s", e.__class__.__name__, _safe_error_message(e))
        log.error("worker startup traceback\n%s", _format_traceback(e))
        sys.exit(1)

    runpod.serverless.start(
        {
            "handler": handler,
            "concurrency_modifier": lambda x: vllm_engine.max_concurrency if vllm_engine else 1,
            "return_aggregate_stream": True,
        }
    )
    shutdown_observability()
