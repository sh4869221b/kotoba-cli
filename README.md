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

## Model Setup

`kotoba init` never downloads a model. Initialize with an existing registered
local model, supply `--model-path`, or import a local GGUF first:

```bash
kotoba models import --id local-ja --path /path/to/model.gguf --use
kotoba init --model-id local-ja --yes
```

For a registered downloadable model, acquire and select it explicitly before
initialization:

```bash
kotoba models pull ID --use
kotoba init --model-id ID --yes
```

Previously, `init --model-id ID` could acquire a URL-only registry entry. It
now exits 1 with an instruction to run `models pull` or provide `--model-path`.
`models pull` keeps its existing HTTPS, direct URL, and Hugging Face command
forms; an HTTPS download completes only when its normal download and checksum
verification succeed.

### Model URL privacy and migration

Remote model URLs containing userinfo (including an empty userinfo) are rejected.
For an explicit `--model-url` pull, the complete encoded query is used for that
request exactly as supplied, while the fragment is removed before acquisition.
Queries are transient: no remote query, including an empty query, is persisted.
The fragment is also omitted from saved metadata.

The registry's `source_url` is informational provenance only. It contains the
remote scheme, authority without userinfo, and encoded path; it is never used as
a download fallback. A query-free HTTPS URL may remain in `download_url`, but a
credential-bearing or query-bearing URL cannot be reused from the registry.
To resupply such a model, enter a fresh URL and checksum explicitly:

```bash
kotoba models pull --model-url https://download.example.invalid/models/model.gguf \
  --id MODEL_ID --checksum SHA256
```

`models pull MODEL_ID` fails before acquisition when no reusable
`download_url` remains, even if the installed file is present. `models use` and
`models verify` continue to operate on the installed path.

Reading the registry does not migrate it: `models info`, `models list`, and
`doctor` leave the file unchanged. The next successful registry write sanitizes
all retained entries, including unrelated legacy entries. Kotoba does not make
a secret backup or sidecar, and cannot erase copies already present in external
backups, shell history, or process inspection. Command-line arguments may be
visible to shell history or other process observers. Secret-looking URL path
components are outside automatic detection; do not supply sensitive paths.

For a manual migration, edit the registry while preserving each model's `id`,
installed `path`, `checksum`, and other descriptive fields. For a URL that
contains credentials or a query, clear `download_url` and retain only a safe
identity in `source_url`, for example:

```toml
download_url = ""
source_url = "https://download.example.invalid/models/model%2Bname.gguf"
```

The `source_url` value above is display/provenance metadata, not a fetch URL.
Run `kotoba doctor` afterward to confirm the registry state, then use a fresh
`--model-url` with the model ID and checksum when the file must be downloaded
again. Do not put credentials into a new registry or backup file.

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

The integration harness gives each run private HOME, XDG directories, model
fixtures, output captures, and a temporary build prefix. Its build snapshot
and deterministic backend contracts are documented in
[docs/test-harness.md](docs/test-harness.md). The harness self-check can be
run without a model:

```bash
bash test/integration/common.sh --self-test
```

Run the deterministic CLI contract matrix and its concurrent integration check:

```bash
bash test/integration/cli_matrix.sh --evidence-dir "$PWD/.omo/evidence/matrix"
bash test/integration/parallel.sh --rounds 2 --evidence-dir "$PWD/.omo/evidence/parallel"
```

The matrix records actual command streams, status, filesystem and translation
memory state using private test/CPU snapshots. It supports `--group translate`,
`commands`, `memory`, or `files`. The parallel driver runs two full matrices per
round alongside existing smoke, benchmark and unit children. See the
[coverage and gaps](docs/test-harness.md#cli-contract-matrix) for the separate
CLI/component evidence and deferred output, mutation and result-validation
guarantees; these tests do not claim real-model quality or atomic file writes.

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
