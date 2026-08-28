# PROJECT KNOWLEDGE BASE

## OVERVIEW
`docs/` records product contracts, embedded runtime integration, privacy guarantees, CI and test evidence boundaries, and historical plans.

## WHERE TO LOOK
| Task | Location | Notes |
| --- | --- | --- |
| Current command/data contract | `design-v1.md` | Update with user-visible behavior changes. |
| Embedded runtime usage | `embedded-llama.md` | Build flags, model import/pull, runtime tuning. |
| llama.cpp API/link contract | `embedded-llama-api.md` | Pinned API list and build/link requirements. |
| Privacy behavior | `privacy.md` | Network, logs, memory, JSON source text. |
| Linux CPU CI | `ci.md`, `../test/ci/linux.sh`, `../.github/workflows/linux-cpu.yml` | Supported host, stages, evidence, required-check procedure. |
| Test contracts and limitations | `test-harness.md`, `../test/integration/` | Backend ownership, fault fixtures, CLI matrix, concurrency. |
| Historical plans | `superpowers/plans/` | Useful context, not automatically current truth. |

## CONVENTIONS
- Keep docs aligned with `README.md`, CLI help/examples, and integration scripts.
- State behavior contracts concretely: stdout/stderr, network boundaries, XDG paths, CUDA skip behavior.
- Treat `docs/privacy.md` as user-facing: update it whenever storage, logging, network, or JSON body inclusion changes.
- Prefer copy-pasteable commands that match current `build.zig` and `test/integration/*.sh`.
- Use the root guide's mise prefix for local compiler and test commands; CI installs its own pinned compiler.
- Distinguish observed CLI behavior, component tests, and deferred guarantees. A characterization test is not a promised future contract.
- Verify test counts and known gaps against current source and runner output before publishing them; old document totals are not assertions.
- Keep CI's configured round count separate from optional local stress examples. A workflow does not itself establish branch protection or a successful remote run.

## ANTI-PATTERNS
- Do not document cloud translation or remote translation backends as supported.
- Do not claim `kotoba init` or `translate` downloads models unless the command path actually does.
- Do not present historical superpowers plans as completed behavior without checking current source/tests.
- Do not omit migration notes when removing or rejecting config keys.
- Do not claim CUDA execution from a successful skip or real-model quality from deterministic fixtures.
- Do not describe pre-operation fault injection as proof of mid-write atomicity or concurrent-writer safety.
