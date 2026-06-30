# PROJECT KNOWLEDGE BASE

## OVERVIEW
`src/models/` owns the model registry, model ID/path validation, checksum verification, Hugging Face/direct URL resolution, and atomic local installation.

## WHERE TO LOOK
| Task | Location | Notes |
| --- | --- | --- |
| Registry parse/save | `registry.zig` | `[[models]]` project-owned TOML subset. |
| Model shape | `types.zig` | Shared `Model` and `List` structs. |
| Local/remote acquisition | `install.zig` | Temp path, checksum, rename. |
| Checksums | `checksum.zig` | SHA-256 verification. |
| Hugging Face selector | `huggingface.zig` | `USER/MODEL[:QUANT]`, file JSON selection. |
| Input validation | `validation.zig` | IDs, `.gguf`, split-file rejection. |

## CONVENTIONS
- Use `models.zig` as the public facade from outside this subtree.
- Validate model IDs before deriving managed paths.
- Use temp files plus `renameFile` for install/download completion.
- Direct HTTPS `--model-url` requires an explicit checksum; local/file registry flows may use existing checksum metadata.
- Split GGUF shards are rejected unless a caller explicitly supports them in the future.

## ANTI-PATTERNS
- Do not allow `http://` downloads.
- Do not make tests require live Hugging Face or internet access; inject fake downloader/JSON where needed.
- Do not delete a managed model file unless no remaining registry entry points to the same real path.
- Do not accept path separators in model IDs.
- Do not write outside the managed model directory when deriving installed paths.
