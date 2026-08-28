# Qwen3.8 Flash Next NVFP4 TP2 on two DGX Sparks

Reproducible SGLang recipe for serving
`RadixArk/Qwen3.8-Flash-Next-NVFP4` across two GB10/DGX Spark-class systems
connected by the direct 200 Gbit/s RoCE fabric.

The production profile favors correctness over speculative throughput:

- TP2 across two SM121 GPUs;
- ModelOpt NVFP4 weights;
- BF16 KV cache and BF16 Mamba/SSM state;
- native 262,144-token context;
- resident PLE embedding;
- RoCE v2 transport with Socket rollback;
- structured `qwen3_coder` tools and `qwen3` reasoning;
- MTP/NEXTN disabled by default;
- OpenAI-compatible API, health endpoint, and Prometheus metrics.

## Pinned artifacts

| Artifact | Pin |
| --- | --- |
| Checkpoint | `RadixArk/Qwen3.8-Flash-Next-NVFP4` |
| Checkpoint revision | `7b719225242aacd3dbd3f9407468c2ee9a9d2594` |
| SGLang image | `lmsysorg/sglang@sha256:12d3392bdc8be8d35e9a95f191df6aef99c5114bdbefd41bfdc7e760e6d25ec1` |
| SGLang source in image | `d91c3682b0b429e4c70df63cd57f819588ce29b0` |

The pinned image needs the narrow SM121 QSA resolver overlay in
[`scripts/prepare-qsa-sm121-patch.sh`](scripts/prepare-qsa-sm121-patch.sh).
The script validates the source file hash before producing the overlay. See
[`docs/PATCHES.md`](docs/PATCHES.md).

## Validated hardware profile

| Role | Management address | Fabric address |
| --- | --- | --- |
| Head | `192.168.1.21` | `10.76.0.1/30` |
| Worker | `192.168.1.22` | `10.76.0.2/30` |

Fabric interface: `enp1s0f0np0`, MTU 9000, 200 Gbit/s. RoCE HCA:
`rocep1s0f0`, GID index 3.

These addresses are examples, not hard-coded runtime requirements. Change them
in the ignored `config.env` for another pair.

## Quick start

Run the recipe from the head node. Passwordless SSH from head to worker must
work over both the management and fabric addresses.

```bash
git clone https://github.com/twistedgrim/qwen38-flash-next-nvfp4-tp2.git
cd qwen38-flash-next-nvfp4-tp2
cp config.example.env config.env
$EDITOR config.env

./qwen38 test
./qwen38 doctor
./qwen38 download --check   # validate an existing checkpoint and image
# ./qwen38 download         # otherwise pull/download/synchronize them
./qwen38 serve
./qwen38 smoke
./qwen38 long-context
./qwen38 bench
./qwen38 status
```

Stop only this recipe's two containers:

```bash
./qwen38 stop
```

`serve` synchronizes the recipe and ignored `config.env` to
`WORKER_RECIPE_DIR`, removes stale recipe containers on both nodes, starts the
worker first, starts the head, and waits for `/health`.

## Commands

| Command | Purpose |
| --- | --- |
| `./qwen38 doctor` | Validate SSH, fabric MTU/IPs, RoCE devices, image, checkpoint, and patch applicability |
| `./qwen38 download` | Pull the immutable image, download on the head, and synchronize weights over the fabric |
| `./qwen38 download --check` | Validate both existing copies against the pinned Hugging Face revision and file sizes |
| `./qwen38 serve` | Synchronize and start TP2, then wait for readiness |
| `./qwen38 smoke` | Test text, separated reasoning, structured tools, tool replay, and C4 tool load |
| `./qwen38 long-context` | Run deterministic 10K, 60K, and 120K retrieval canaries |
| `./qwen38 bench` | Run warm-cache streaming throughput gates at C1, C2, and C4 |
| `./qwen38 status` | Show both containers, endpoint, Mamba/KV metrics, and recent errors |
| `./qwen38 stop` | Remove only this recipe's containers |
| `./qwen38 test` | Run shell/Python/config static tests |

The target Ubuntu hosts need Bash, Python 3, Docker, OpenSSH, rsync, curl,
`iproute2`, `sha256sum`, `awk`, and normal POSIX text utilities. The checkpoint
downloader runs `huggingface_hub` from the pinned SGLang container so it does
not modify the host Python installation.

## Validated serving state

The MTP-off/RoCE production start reported, per rank:

```text
weights: ModelOpt NVFP4
Mamba cache: 449 states, BF16, 0.46 GiB convolution + 11.87 GiB SSM
KV cache: 1,130,880 tokens, BF16, 6.47 GiB K + 6.47 GiB V
context: 262,144
max running requests: 4
```

Measured aggregate output throughput with cache flushing between controlled
runs was approximately:

| Concurrency | Output tok/s |
| ---: | ---: |
| C1 | 25.47 |
| C2 | 50.15 |
| C4 | 79.61 |

The clean recipe validation receipt is recorded in
[`docs/RESULTS-2026-08-27.md`](docs/RESULTS-2026-08-27.md).

Benchmark methodology matters. The command performs an explicit warmup and
enforces conservative minimum aggregate rates of 20/40/65 tok/s at C1/C2/C4.
It does not flush the radix cache between runs. Re-run it after image, transport,
memory, scheduler, graph, or checkpoint changes rather than comparing unrelated
prompt suites.

## Why MTP is off

NEXTN `3/1/4` raised aggregate throughput to about 55/86/117 tok/s at C1/C2/C4,
but repeated seeded 10K-120K retrieval prompts intermittently emitted token ID
0 (`!`). A smaller `2/1/3` profile passed a bounded suite but was not promoted.
MTP remains available only as an explicit experimental switch in `config.env`.

Any MTP promotion must pass:

1. plain text, reasoning, structured tools, and tool-result replay;
2. four concurrent tool-carrying requests while observing Mamba usage;
3. repeated non-repetitive 10K, 60K, and 120K retrieval canaries with early,
   middle, and late needles plus strict prompt-token accounting;
4. output scans for bang runs, NaN/Inf, malformed tool arguments, and drift;
5. controlled C1/C2/C4 benchmarks against the MTP-off baseline.

`QWEN38_MTP_ATTENTION_MODE=decode` is retained as a future experiment because a
Spark Arena run used it, but it has not passed this recipe's correctness gates.

## llama-swap and LiteLLM

The optional routing assets add the normal shared-gateway path:

```text
client → LiteLLM gx10-qwen3.8-flash-next
       → llama-swap qwen3.8-flash-next-nvfp4
       → SGLang TP2 on the GX10 pair
```

- [`integrations/llama-swap/model.yaml`](integrations/llama-swap/model.yaml)
  contains the lifecycle route. Its wrapper propagates llama-swap's dynamic
  backend port to both TP ranks and keeps the command alive while serving.
- [`integrations/litellm/model.yaml`](integrations/litellm/model.yaml) contains
  the stable client alias. It references the injected
  `GX10_LLAMA_SWAP_BASE_URL` and `GX10_VLLM_API_KEY`; no deployment-specific
  address or credential is stored there.
- [`docs/ROUTING-2026-08-27.md`](docs/ROUTING-2026-08-27.md) records the
  end-to-end llama-swap, LiteLLM, tools, and Pi validation.

The Qwen route must be a member of the same exclusive llama-swap group as the
other TP2 models. A first request can take several minutes because llama-swap
must unload the active model and perform a full two-rank cold start. While
llama-swap owns the workload, SGLang listens on a private dynamic port; `:30000`
is the manual diagnostic path used only by direct `./qwen38 serve` launches.

## Rollbacks

Use Socket transport without editing the recipe:

```bash
QWEN38_NCCL_TRANSPORT=socket ./qwen38 serve
```

Disable any experimental MTP override:

```bash
QWEN38_ENABLE_MTP=0 ./qwen38 serve
```

The checkpoint, image, transport, MTP, cache limits, and serving flags are
independent settings so each can be tested and reverted separately.

## Repository hygiene

`config.env`, generated patches, benchmark results, credentials, model weights,
and caches are ignored. Do not add Hugging Face tokens, SSH keys, API keys, or
host-specific protected environment files to this repository.

## Credits and license

Repository-local scripts and documentation are available under the
[MIT License](LICENSE). Model weights, the generated SGLang overlay, container
images, CUDA/NCCL, and other upstream components retain their own terms. See
[CREDITS.md](CREDITS.md) for attribution and license boundaries.
