# Embedded llama.cpp API Contract

Pinned upstream submodule: `ggml-org/llama.cpp` commit `9c92e96a64fe0f03f5f3e5ab720a151941da1de5`.

Kotoba embeds the llama.cpp library API from `vendor/llama.cpp/include/llama.h`.

Initial CPU-only lifecycle:

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
- Disable tools, examples, tests, server, app, common, and OpenMP for the first embedded runtime.
- Link `llama`, `ggml`, `ggml-base`, and `ggml-cpu`.
- Include `vendor/llama.cpp/include` and `vendor/llama.cpp/ggml/include`.
- Compile `src/llama_api_probe.c` with `-fsyntax-only` during the Zig build to
  fail early when the pinned C API drifts.

Fresh checkouts must initialize submodules before building:

```bash
git submodule update --init --recursive
```
