# Embedded llama.cpp Runtime

Kotoba builds llama.cpp into the CLI and loads the selected local GGUF model in
the current process. GGUF model files remain user-managed assets and are stored
or referenced through the model registry.

Fresh source checkouts must initialize the pinned llama.cpp submodule before
building:

```bash
git submodule update --init --recursive
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
context_length = 4096
threads = 0
max_tokens = 1024
temperature = 0.2
timeout_sec = 120
```

Normal translation does not perform network I/O. Network access occurs only for
explicit model downloads.
