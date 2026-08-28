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
- `llama_get_memory`
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
- `llama_log_set`

Build contract:

- Use Zig 0.16.0 and initialize the submodule before even `zig build --help`.
- Require the canonical submodule Git toplevel, actual checkout HEAD, parent
  index gitlink, and documented pin to match the full commit above. A parent
  repository discovered through a missing submodule `.git` is not accepted.
  The CI contract also checks the HEAD gitlink.
- Missing checkout reports `llama.cpp submodule is not initialized; run git
  submodule update --init --recursive`; a wrong checkout/gitlink reports
  `llama.cpp pin mismatch: expected 9c92e96a64fe0f03f5f3e5ab720a151941da1de5`.
- Configure both `LLAMA_BUILD_COMMIT` and `GGML_BUILD_COMMIT` with the full
  pin and verify the CMake cache before/after configuration. Inconsistent
  metadata fails with `llama.cpp metadata mismatch`. Upstream's effective
  `GGML_COMMIT` compiler define is its Git short SHA, not a full SHA.
- Configure llama.cpp with `BUILD_SHARED_LIBS=OFF`.
- Build CPU by default with `GGML_CUDA=OFF`.
- Build CUDA only when requested with `zig build -Dcuda=true`, using the
  separate `<local-cache>/llama.cpp/cuda` directory and `GGML_CUDA=ON`.
  CPU output uses `<local-cache>/llama.cpp/cpu`. The default local cache is
  `.zig-cache`; `--cache-dir` overrides it, while `--prefix` controls installation.
  Old vendor build caches are unused and never automatically removed.
- If CUDA Toolkit discovery fails during a CUDA-requested build, fail the build
  instead of falling back silently.
- On Linux, link `ggml-cuda` and CUDA shared libraries dynamically for CUDA
  builds. `-Dcuda-lib-dir=/absolute/path` may be used to add a non-standard
  CUDA library directory.
- Disable tools, examples, tests, server, app, common, and OpenMP for the embedded build.
- Link `llama`, `ggml`, `ggml-base`, and `ggml-cpu`.
- On Linux, use Zig's LLVM backend and bundled LLD for both the CLI and unit-test
  binaries. Zig 0.16.0's native linker cannot handle `R_X86_64_PC64` relocations
  in `.sframe` sections emitted by some system CRT objects. Enable LLVM together
  with LLD; macOS keeps the default backend and linker.
- Link `ggml-cuda`, `cuda`, `cudart`, `cublas`, and `cublasLt` only for
  CUDA-enabled builds.
- Include `vendor/llama.cpp/include` and `vendor/llama.cpp/ggml/include`.
- Compile `src/llama_api_probe.c` with `-fsyntax-only` and
  `-Werror=incompatible-pointer-types` during the Zig build. Exact function
  pointer signatures cover every llama API called by the adapter, plus used
  model/context fields and callbacks. The real production Zig compilation
  remains an additional contract check; neither check requires inference.

Translation contract:

- `backend.Request` is borrowed for one call and carries `model_id`, the
  complete `source_text`, resolved `source_lang` and `target_lang`, the
  rendered `prompt`, and `timeout_sec`.
- Both the embedded session and the deterministic test session return the
  same owned `translation_contract.Result`. The caller frees `Result.text`
  with `Result.deinit(allocator)` on success and failure paths.
- The test session's optional per-instance fixture copies explicit bytes
  verbatim. Without one, it returns `JA:<source_text>` or `EN:<source_text>`
  from `target_lang`; it does not inspect or parse the rendered prompt.

The finish reason and consumer mapping are:

| Finish reason | Meaning | Translation consumer |
| --- | --- | --- |
| `eog` | The model emitted an end-of-generation token. | Success; append and cache the returned bytes. |
| `max_tokens` | The generation loop reached its configured limit. | Success; append and cache the returned bytes. |
| `context` | Prompt or decode could not fit the context/KV space. | `LlamaDecodeFailed`; no append or cache write for that segment. |
| `timeout` | The request deadline elapsed, including timeout taking precedence over a decode status. | `Timeout`; no append or cache write for that segment. |
| `decode` | Tokenization, token-piece conversion, or another decode operation failed. | `LlamaDecodeFailed`; no append or cache write for that segment. |

Empty, whitespace, invalid UTF-8, and truncated bytes remain representable
payloads. They are not rejected or reclassified by this contract. A later
segment failure does not roll back cache writes made by earlier successful
segments.

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

`zig build test` and `zig build` exercise the production branch without a real
model. The model-free production checks include the decode-status classifier;
they do not constitute real llama.cpp sampling coverage. The deterministic
backend is selected only at build time with `-Dtest-backend=true`.

Fresh checkouts must initialize submodules before building:

```bash
git submodule update --init --recursive
```
