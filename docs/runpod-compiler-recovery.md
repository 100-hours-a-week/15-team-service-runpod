# RunPod Startup Failure Recovery (Missing C Compiler)

This runbook covers the startup failure where vLLM crashes with:

`torch._inductor.exc.InductorError: RuntimeError: Failed to find C compiler`

## 1) Immediate Recovery (No Image Change)

Use this to restore service quickly:

1. Open the RunPod endpoint configuration.
2. Set environment variable `ENFORCE_EAGER=true`.
3. Restart or redeploy the endpoint.
4. Confirm startup is stable and no startup loop occurs.
5. Run one inference request and confirm success.

Note: This may reduce throughput/performance compared to compiled execution paths.

## 2) Permanent Fix (Image Update)

The container image must include compiler toolchain and Python headers for Triton/Inductor runtime compilation.

Required image changes (already applied in `Dockerfile`):

- install `build-essential`
- install `python3-dev`
- set `CC=/usr/bin/gcc`
- set `CXX=/usr/bin/g++`

## 3) Verification Checklist

After building and deploying the updated image:

1. Image sanity checks:
   - `which cc`
   - `cc --version`
   - `python3 -c "import triton, torch"`
   - optional: run `builder/verify_runtime_toolchain.sh` inside the container
2. Runtime checks with `ENFORCE_EAGER=false`:
   - worker starts successfully
   - first inference request succeeds
   - logs contain no `InductorError`
   - logs contain no `Failed to find C compiler`
3. Regression checks:
   - run `.runpod/tests_json` basic inference
   - run one OpenAI route request (`/openai/v1/chat/completions`)

## 4) Rollout and Rollback

Rollout:

1. Deploy to one canary endpoint first.
2. Observe 30-60 minutes (startup stability, error rate, latency).
3. Roll out to remaining endpoints.

Rollback:

1. Revert to previous image.
2. Set `ENFORCE_EAGER=true` to keep service available.
