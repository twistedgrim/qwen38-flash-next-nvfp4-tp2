# Validation gates

Run these from the head node after every serving change:

```bash
./qwen38 test
./qwen38 doctor
./qwen38 download --check
./qwen38 serve
./qwen38 smoke
./qwen38 long-context
./qwen38 bench
./qwen38 status
```

## Required evidence

A production candidate must show:

- both containers remain running;
- `/health`, `/v1/models`, and `/metrics` return HTTP 200;
- the expected model ID is served;
- RoCE starts through NCCL `NET/IB` when RoCE is selected;
- ModelOpt NVFP4 weights load;
- BF16 KV and Mamba/SSM caches allocate;
- Mamba usage remains below exhaustion during C4 load;
- plain response, separated reasoning, structured tool call, and tool-result
  replay gates pass;
- no repeated token-ID-0 (`!`) output, NaN/Inf, malformed tool JSON, CUDA/NCCL
  errors, or container restart;
- retrieval succeeds at approximately 10K, 60K, and 120K prompt tokens;
- C1/C2/C4 throughput does not materially regress against the recorded baseline.

## Test boundaries

The smoke test invokes tools but never executes them. Its absolute paths are
arguments returned by the model, not local filesystem mutations.

The long-context test creates deterministic, non-repetitive ledger records in
client memory and sends them directly to the endpoint. It does not write the
prompts or model output to disk.

`bench` measures completion tokens reported by the API and wall-clock streaming
time. It rejects early completions and long bang runs. Results are written only
when `--output` is supplied; `results/` is ignored.

## Configuration promotion

Change one independent dimension at a time:

1. checkpoint;
2. image/runtime;
3. transport;
4. attention or graph flags;
5. memory/KV/SSM settings;
6. speculative decoding.

Capture the prior `status`, run all gates, compare benchmarks using the same
prompt suite, and keep a direct environment-variable rollback.
