# Embedded llama.cpp Runtime

Kotoba builds llama.cpp into the CLI and loads the selected local GGUF model in
the current process. GGUF model files remain user-managed assets and are stored
or referenced through the model registry.

Fresh source checkouts must initialize the pinned llama.cpp submodule before
building:

```bash
git submodule update --init --recursive
zig build
```

The default build configures llama.cpp without CUDA and is the portable CPU
path. CUDA is opt-in:

```bash
zig build -Dcuda=true
```

`-Dcuda=true` configures the separate CUDA llama.cpp build directory and links
the CUDA backend. The CUDA request is intentionally strict: if the CUDA Toolkit
is missing, CMake fails instead of silently producing a CPU-only CUDA build. On
Linux the CUDA libraries are dynamically linked, so the CUDA shared libraries
must also be visible to the dynamic loader when running the resulting binary.
If they live in a non-standard directory, provide it explicitly:

```bash
zig build -Dcuda=true -Dcuda-lib-dir=/absolute/path/to/cuda/lib64
```

Import an existing local model:

```bash
kotoba models import --id local-ja --path /path/to/model.gguf --checksum SHA256 --use
```

Download a model from Hugging Face:

```bash
kotoba models pull --hf-repo ggml-org/GLM-4.7-Flash-GGUF:Q4_K_M --use
kotoba models pull --hf-repo ggml-org/GLM-4.7-Flash-GGUF --hf-file GLM-4.7-Flash-Q4_K_M.gguf --id glm-4.7-flash-q4 --use
```

Download from a direct HTTPS GGUF URL:

```bash
kotoba models pull --model-url https://example.com/model.gguf --id example-q4 --checksum SHA256 --use
```

Inspect and verify model state:

```bash
kotoba models list
kotoba models info local-ja
kotoba models verify
kotoba doctor
```

Runtime tuning is exposed through config keys. Discover supported keys with:

```bash
kotoba config list
```

Common embedded runtime settings:

```toml
gpu_layers = -1
context_length = 4096
threads = 0
max_tokens = 1024
temperature = 0.2
timeout_sec = 120
```

`gpu_layers` is signed. Any negative value requests full GPU offload through
llama.cpp when a CUDA-capable binary and GPU backend are available. `0` is the
CPU fallback setting, and a positive value requests an exact number of layers.
CPU-only builds remain valid and run without CUDA.

Benchmark the deterministic translation path with:

```bash
zig build bench
bash test/integration/bench.sh
```

Optional CUDA QA is guarded for developer machines with a local GGUF model:

```bash
KOTOBA_CUDA_MODEL=/path/to/model.gguf bash test/integration/cuda_smoke.sh
```

Without `KOTOBA_CUDA_MODEL` or `nvidia-smi`, the CUDA smoke script reports a
skip and exits successfully.

Normal translation does not perform network I/O. Network access occurs only for
explicit model downloads.
