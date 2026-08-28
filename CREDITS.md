# Credits and upstream licenses

This recipe packages and validates public model-serving work from several
projects. Credit the upstream authors when reusing the checkpoint, runtime,
patch, or benchmark evidence.

## Model

- [`RadixArk/Qwen3.8-Flash-Next-NVFP4`](https://huggingface.co/RadixArk/Qwen3.8-Flash-Next-NVFP4)
  provides the ModelOpt NVFP4 checkpoint used by this recipe.
- The checkpoint identifies [`Qwen/Qwen3.8-Flash-Next`](https://huggingface.co/Qwen/Qwen3.8-Flash-Next)
  as its base model.

The checkpoint currently reports `license: other` on Hugging Face. Model
weights are not distributed by this repository. Review and comply with the
model card and upstream terms before downloading or redistributing weights.

## Serving runtime

- [SGLang](https://github.com/sgl-project/sglang) provides the serving engine
  and is licensed under Apache-2.0.
- [FlashInfer](https://github.com/flashinfer-ai/flashinfer) provides inference
  kernels used by the validated path and is licensed under Apache-2.0.
- NVIDIA CUDA, NCCL, the container runtime, and DGX Spark/GB10 platform
  components remain under their respective NVIDIA terms.

The generated QSA overlay modifies one module from the pinned SGLang image.
That generated derivative retains its upstream Apache-2.0 license. See
[`docs/PATCHES.md`](docs/PATCHES.md) for exact provenance and safeguards.

## Community evidence

- [MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks)
  provided an early dual-Spark deployment reference.
- [tonyd2wild/Qwen3.8-Flash-Next-NVFP4-DGX-Spark](https://github.com/tonyd2wild/Qwen3.8-Flash-Next-NVFP4-DGX-Spark)
  documented Mamba-state exhaustion under concurrency and informed the
  recipe's explicit concurrency/Mamba validation gate.
- [Spark Arena](https://spark-arena.com/) provided an independently published
  benchmark configuration used as comparison evidence, not as an automatic
  production configuration.
- [tonyd2wild/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark](https://github.com/tonyd2wild/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark)
  and the companion Inkling recipe provided useful examples for packaging a
  validated two-node Spark deployment as a public, reproducible repository.

## Repository contribution

This repository contributes the independently validated two-node Qwen3.8
Flash-Next NVFP4 configuration, immutable artifact pins, SM121 QSA overlay
guard, RoCE/Socket rollback, correctness gates, long-context retrieval suite,
concurrency benchmark, and llama-swap/LiteLLM integration.

Repository-local scripts and documentation are MIT licensed via [`LICENSE`](LICENSE).
Model weights, generated upstream overlays, base images, and external runtime
components retain their own licenses and are not relicensed by this repository.
