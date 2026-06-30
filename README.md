# Kotoba CLI

Kotoba CLI is a local-first translation CLI written in Zig. It embeds the
llama.cpp inference engine and runs translation in-process against a selected
local GGUF model.

```bash
kotoba models import --id local-ja --path /path/to/model.gguf --use
kotoba translate "Hello world" --to ja
```

Normal translation performs no network request. Network access is used only
when you explicitly run `kotoba models pull` for an HTTPS model source.

JSON output omits source text unless `--include-source` is specified.
Translation memory stores source and translated text unless memory is disabled.

## Output Contract

`kotoba translate` is quiet by default. For `plain` and `markdown` output,
stdout contains only the translated text, even when running interactively in a
terminal. Diagnostics, model-load details, and progress output are suppressed
unless debug output is explicitly requested.

Use `--format json` when callers need metadata such as cache status, warnings,
runtime, or elapsed time. Use `--debug` only when diagnosing runtime behavior;
debug output may be written to stderr and never changes translated stdout.

## Commands

```bash
kotoba init [--model-id ID] [--model-path PATH] [--yes]
kotoba translate [TEXT] --to ja [--debug]
kotoba translate --file README.md --to ja [--debug]
cat README.md | kotoba translate --to ja --format markdown [--debug]
kotoba doctor
kotoba config list
kotoba config get model_path
kotoba config set max_tokens 512
kotoba models list
kotoba models info ID
kotoba models import --id ID --path PATH [--name NAME] [--checksum SHA256] [--use]
kotoba models pull ID [--output PATH] [--use]
kotoba models pull --hf-repo USER/MODEL[:QUANT] [--hf-file FILE] [--id ID] [--use]
kotoba models pull --model-url HTTPS_URL --id ID --checksum SHA256 [--use]
kotoba models use ID
kotoba models verify [ID]
kotoba models remove ID --yes
kotoba memory status
kotoba glossary validate
```

## Build

Initialize the pinned llama.cpp submodule before building from a fresh clone:

```bash
git submodule update --init --recursive
zig build
```

The default build is CPU-only and does not require CUDA. To build an
opt-in CUDA-enabled binary, install the CUDA Toolkit and run:

```bash
zig build -Dcuda=true
```

On Linux, the CUDA build links the llama.cpp CUDA backend and the CUDA shared
libraries dynamically. If your Toolkit libraries are outside the standard
search paths, pass an absolute library directory:

```bash
zig build -Dcuda=true -Dcuda-lib-dir=/absolute/path/to/cuda/lib64
```

Requesting `-Dcuda=true` is strict: the build fails when the CUDA Toolkit or
required CUDA libraries are unavailable. The default `zig build` path remains
CPU-only and continues to work without CUDA. A CUDA-linked binary still needs
the CUDA shared libraries available to the dynamic loader at run time; use the
default build or set `gpu_layers = 0` when you want CPU execution.

Run the deterministic translation benchmark with:

```bash
zig build bench
bash test/integration/bench.sh
```

Real CUDA QA is guarded so non-CUDA machines can run it safely:

```bash
KOTOBA_CUDA_MODEL=/path/to/model.gguf bash test/integration/cuda_smoke.sh
```

If `KOTOBA_CUDA_MODEL` or `nvidia-smi` is unavailable, the CUDA smoke script
prints a skip message and exits successfully.

The embedded llama.cpp build is verified on Linux and has native macOS linker
handling for the default CPU path; other hosts are not wired yet.

Markdown translation protects code spans, code fences, URLs, frontmatter, and
Markdown tables. Tables are intentionally left untranslated in v1.0 to avoid
breaking their structure.

Configuration follows XDG paths:

- `~/.config/kotoba/config.toml`
- `~/.config/kotoba/models.toml`
- `~/.config/kotoba/glossary.toml`
- `~/.local/share/kotoba/models/`
- `~/.local/share/kotoba/memory.sqlite3`

Embedded runtime config keys include:

- `model_id`
- `model_path`
- `gpu_layers`
- `context_length`
- `threads`
- `max_tokens`
- `temperature`
- `timeout_sec`

`gpu_layers` is a signed integer. Negative values, including the default `-1`,
request all model layers to be offloaded when the binary has a GPU backend
available. `0` forces CPU execution, and positive values request that exact
number of layers.
