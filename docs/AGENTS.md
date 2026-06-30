# PROJECT KNOWLEDGE BASE

## OVERVIEW
`docs/` records product contracts for the local-first translator, embedded llama.cpp runtime, privacy guarantees, and historical implementation plans.

## WHERE TO LOOK
| Task | Location | Notes |
| --- | --- | --- |
| Current command/data contract | `design-v1.md` | Update with user-visible behavior changes. |
| Embedded runtime usage | `embedded-llama.md` | Build flags, model import/pull, runtime tuning. |
| llama.cpp API/link contract | `embedded-llama-api.md` | Pinned API list and build/link requirements. |
| Privacy behavior | `privacy.md` | Network, logs, memory, JSON source text. |
| Historical plans | `superpowers/plans/` | Useful context, not automatically current truth. |

## CONVENTIONS
- Keep docs aligned with `README.md`, CLI help/examples, and integration scripts.
- State behavior contracts concretely: stdout/stderr, network boundaries, XDG paths, CUDA skip behavior.
- Treat `docs/privacy.md` as user-facing: update it whenever storage, logging, network, or JSON body inclusion changes.
- Prefer copy-pasteable commands that match current `build.zig` and `test/integration/*.sh`.

## ANTI-PATTERNS
- Do not document cloud translation or remote translation backends as supported.
- Do not claim `kotoba init` or `translate` downloads models unless the command path actually does.
- Do not present historical superpowers plans as completed behavior without checking current source/tests.
- Do not omit migration notes when removing or rejecting config keys.
