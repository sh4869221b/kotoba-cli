# Embedded llama.cpp API Contract

Pinned upstream submodule: `ggml-org/llama.cpp` commit `9c92e96a64fe0f03f5f3e5ab720a151941da1de5`.

Kotoba embeds the llama.cpp library API from `vendor/llama.cpp/include/llama.h`.

Embedded lifecycle:

- `llama_backend_init`
- `llama_model_default_params`
- `llama_model_load_from_file`
- `llama_context_default_params`
- `llama_init_from_model`
- `llama_model_get_vocab`
- `llama_tokenize`
- `llama_batch_get_one`
- `llama_decode`
- `llama_memory_clear`
- `llama_sampler_chain_default_params`
- `llama_sampler_chain_init`
- `llama_sampler_chain_add`
- `llama_sampler_init_temp`
- `llama_sampler_init_top_p`
- `llama_sampler_init_greedy`
- `llama_sampler_init_dist`
- `llama_sampler_sample`
- `llama_sampler_accept`
- `llama_sampler_reset`
- `llama_vocab_is_eog`
- `llama_token_to_piece`
- `llama_sampler_free`
- `llama_free`
- `llama_model_free`
- `llama_backend_free`

Build contract:

- Configure llama.cpp with `BUILD_SHARED_LIBS=OFF`.
- Build CPU by default with `GGML_CUDA=OFF`.
- Build CUDA only when requested with `zig build -Dcuda=true`, using the
  separate `vendor/llama.cpp/build-kotoba-cuda` directory and `GGML_CUDA=ON`.
- If CUDA Toolkit discovery fails during a CUDA-requested build, fail the build
  instead of falling back silently.
- On Linux, link `ggml-cuda` and CUDA shared libraries dynamically for CUDA
  builds. `-Dcuda-lib-dir=/absolute/path` may be used to add a non-standard
  CUDA library directory.
- Disable tools, examples, tests, server, app, common, and OpenMP for the embedded build.
- Link `llama`, `ggml`, `ggml-base`, and `ggml-cpu`.
- Link `ggml-cuda`, `cuda`, `cudart`, `cublas`, and `cublasLt` only for
  CUDA-enabled builds.
- Include `vendor/llama.cpp/include` and `vendor/llama.cpp/ggml/include`.
- Compile `src/llama_api_probe.c` with `-fsyntax-only` during the Zig build to
  fail early when the pinned C API drifts.

GPU offload contract:

- `Config.gpu_layers` is passed to `llama_model_params.n_gpu_layers`.
- Any negative value requests all layers according to llama.cpp semantics.
- `0` is CPU fallback.
- Positive values request an exact layer count.
- String aliases such as `auto` or `all` are not accepted.

Benchmark and QA contract:

- `zig build bench` runs `test/integration/bench.sh`.
- `bash test/integration/bench.sh` builds the deterministic test backend and
  emits JSON for the translation benchmark.
- `bash test/integration/cuda_smoke.sh` is optional and guarded; it skips
  successfully unless `KOTOBA_CUDA_MODEL` and `nvidia-smi` are available.

Fresh checkouts must initialize submodules before building:

```bash
git submodule update --init --recursive
```
