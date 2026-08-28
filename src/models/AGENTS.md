# PROJECT KNOWLEDGE BASE

## OVERVIEW
`src/models/` owns the model registry, model ID/path validation, checksums, Hugging Face resolution, and staged GGUF installation.

## WHERE TO LOOK
| Task | Location | Notes |
| --- | --- | --- |
| Registry parse/save | `registry.zig` | `[[models]]` project-owned TOML subset. |
| Model shape | `types.zig` | Shared `Model` and `List` structs. |
| Local/remote acquisition | `install.zig` | Temp path, checksum, rename. |
| Checksums | `checksum.zig` | SHA-256 verification. |
| Hugging Face selector | `huggingface.zig` | `USER/MODEL[:QUANT]`, file JSON selection. |
| Input validation | `validation.zig` | IDs, `.gguf`, split-file rejection. |
| URL policy | `../url.zig` | Request bytes, reusable download URLs, safe display/source identity. |

## CONVENTIONS
- Use `../models.zig` as the public facade from outside this subtree; its `installedPath` exports the validated registry helper.
- Model IDs accept only ASCII alphanumerics, `-`, `_`, and `.`; validate before deriving managed paths.
- `load` fails on missing registries; `loadReadOnly` uses the default template in memory only for `FileNotFound`. Neither loader writes or sanitizes the file.
- `save` sanitizes every entry's URL metadata, including through `upsert`; keep read paths nonmutating.
- Install to a sibling temporary file, verify any supplied checksum, then `renameFile`; failures clean the temporary path and preserve the destination.
- File installation is not an atomic transaction with subsequent registry/config writes in `../cli/models_cmd.zig`.
- Direct HTTPS `--model-url` requires an explicit checksum; local/file registry flows may use existing checksum metadata.
- HF filenames must be relative `.gguf` paths without empty/dot segments, backslashes, `?`, or `#`; HF resolution rejects split GGUF shards.
- Test acquisition through `acquireWithDownloader` and HF selection with fixture JSON.

## URL METADATA
- Acquisition must reject remote userinfo before invoking the downloader; follow `../url.zig` for request/display parsing.
- Persist a remote `download_url` only when it is valid, query-free HTTPS; strip fragments. Query-bearing sources require a fresh explicit URL for another pull.
- `source_url` is informational safe identity, never a fallback download source.
- Preserve literal `?` and `#` in local paths and `file://` values; remote URL cleanup must not alter local filenames.

## ANTI-PATTERNS
- Do not allow `http://` downloads.
- Do not bypass `../cli/models_cmd.zig`'s deletion guard: the real path must be inside the managed directory and unreferenced by remaining registry entries.
- Do not write outside the managed model directory when deriving installed paths.
