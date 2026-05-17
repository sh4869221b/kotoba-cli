# llama-server Autostart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Kotoba start a local `llama-server` process itself when translation/init needs a local llama.cpp-compatible server and no server is already reachable.

**Architecture:** Keep `src/llama.zig` focused on HTTP/OpenAI-compatible requests and add a small runtime manager module that owns local process startup, readiness polling, and cleanup. Autostart must only apply to loopback `server_url` values and must never start or contact a remote endpoint unless the existing explicit remote opt-in is used.

**Tech Stack:** Zig CLI, libc/socket HTTP adapter, `std.process` child process management, existing XDG TOML config, shell integration smoke tests with the Python fake llama server.

---

## Current State

- `README.md` and `docs/llama-server.md` currently document that users must start `llama-server` themselves.
- `src/llama.zig` validates local loopback URLs, performs `/health`, and posts to `/v1/chat/completions`.
- `src/translate.zig` calls `llama.translateSegment` directly for uncached segments.
- `src/cli.zig` `init` writes config, checks server health, and warns if the server is absent.
- `test/integration/smoke.sh` starts `test/integration/fake_llama_server.py` before invoking `kotoba`.

## Target Behavior

- If `server_url` is local loopback and `/health` succeeds, use the already-running server.
- If `/health` fails, `server_autostart = true`, `runtime = "llama_server"`, and `model_path` exists, start:

```bash
llama-server -m <model_path> --host <host> --port <port>
```

- Wait until `/health` succeeds or `server_startup_timeout_sec` expires.
- Keep the child process alive for the current `kotoba` command only, then terminate it during cleanup.
- Do not autostart for non-loopback `server_url`, even when `--allow-remote-server` is supplied. A loopback `server_url` remains eligible for autostart even if `--allow-remote-server` is also present.
- Do not autostart for loopback URLs with a non-empty base path such as `http://127.0.0.1:8080/v1`. Treat those as user-managed endpoints because `llama-server` is started at the root path while Kotoba's HTTP adapter appends the configured base path to request targets.
- Do not autostart unless `runtime = "llama_server"`.
- For `translate`, do not autostart when `model_path` is empty or missing; fail with the existing model/server guidance plus a more direct runtime hint. For `init`, missing model/runtime pieces are warning-only when current init behavior already tolerates an unreachable server.
- `doctor` remains mostly non-mutating: it reports autostart configuration and whether the binary/model are usable, but it should not start `llama-server` unless a future explicit `doctor --start-server` command is added.
- Startup coordination must be bounded: a stale lock from a crashed Kotoba process must not block future autostart attempts indefinitely.

## File Structure

- Modify `src/config.zig`
  - Add persisted runtime settings:
    - `server_autostart: bool = true`
    - `llama_server_path: []const u8 = "llama-server"`
    - `server_startup_timeout_sec: u32 = 60`
  - Parse, save, and allow `config set` for these keys and the existing `runtime` key.
- Modify `src/llama.zig`
  - Expose a small parsed endpoint helper for loopback host/port/base path reuse.
  - Keep request/translation behavior unchanged.
- Create `src/runtime.zig`
  - Own `ensureServer`, child process lifecycle, readiness polling, and command argument construction.
  - Own shared executable resolution for `llama_server_path`; `doctor` and startup must use the same resolver.
  - Own startup coordination so concurrent Kotoba invocations do not blindly spawn duplicate servers.
  - Return an optional managed process handle that callers `defer close()`.
- Modify `src/translate.zig`
  - Extend `translate.run` to receive `xdg.Paths` or a focused runtime path struct, then call the runtime manager before the first uncached llama request.
  - Start at most once per command, not once per segment.
- Modify `src/cli.zig`
  - `init`: load existing config when present, preserve runtime/autostart fields unless explicitly changed, then after config write try managed startup when autostart is enabled and model path is present.
  - `config get`: print new keys.
- Modify `src/doctor.zig`
  - Add runtime/autostart checks without process startup side effects.
- Modify `src/errors.zig`
  - Add clear errors such as `server_start_failed` and `server_startup_timeout`.
- Modify `src/sys.zig`
  - Add small process/signal helpers only if needed by `src/runtime.zig`.
- Modify `src/main.zig`
  - Add `runtime` to `refAllDecls`.
- Modify docs:
  - `README.md`
  - `docs/llama-server.md`
  - `docs/privacy.md`
  - `docs/design-v1.md`
- Modify tests:
  - `test/integration/fake_llama_server.py`
  - `test/integration/smoke.sh`
  - Add a stalled-server test fixture or mode for deterministic timeout coverage.

## Task 1: Config Surface

**Files:**
- Modify: `src/config.zig`
- Modify: `src/cli.zig`
- Test: `src/config.zig`, existing CLI smoke path

- [ ] **Step 1: Add failing config parse/round-trip tests**

Cover these TOML keys:

```toml
server_autostart = true
llama_server_path = "/tmp/fake-llama-server"
server_startup_timeout_sec = 3
```

Expected parsed values:

- `cfg.server_autostart == true`
- `cfg.llama_server_path == "/tmp/fake-llama-server"`
- `cfg.server_startup_timeout_sec == 3`

- [ ] **Step 2: Run the unit test and confirm it fails**

Run:

```bash
zig build test
```

Expected: failure because the new fields are not implemented.

- [ ] **Step 3: Implement config fields**

Add defaults to `Config`:

```zig
server_autostart: bool = true,
llama_server_path: []const u8 = "llama-server",
server_startup_timeout_sec: u32 = 60,
```

Update `parse`, `save`, and `setValue`.

- [ ] **Step 4: Expose `config get` for new keys**

Update `printConfigValue` in `src/cli.zig` for:

- `runtime`
- `server_autostart`
- `llama_server_path`
- `server_startup_timeout_sec`

- [ ] **Step 5: Add CLI-level config set/get checks**

Add a smoke or unit-level CLI assertion that writes and reads back every new key:

```bash
kotoba config set server_autostart false
test "$(kotoba config get server_autostart)" = "false"
kotoba config set runtime llama_server
test "$(kotoba config get runtime)" = "llama_server"
kotoba config set llama_server_path /tmp/fake-llama-server
test "$(kotoba config get llama_server_path)" = "/tmp/fake-llama-server"
kotoba config set server_startup_timeout_sec 5
test "$(kotoba config get server_startup_timeout_sec)" = "5"
```

These checks must not rely on `PATH` fallback; they should prove the config command path works.

- [ ] **Step 6: Verify**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/config.zig src/cli.zig
git commit -m "feat: add llama server autostart config"
```

## Task 2: Local Endpoint Reuse

**Files:**
- Modify: `src/llama.zig`
- Test: `src/llama.zig`

- [ ] **Step 1: Add tests for extracting local endpoint**

Cases:

- `http://127.0.0.1:8080` -> host `127.0.0.1`, port `8080`
- `http://localhost:18080` -> host `127.0.0.1` for process args, port `18080`
- `http://[::1]:18080` -> host `::1`, port `18080`
- lock key canonicalization maps `localhost` and `127.0.0.1` with the same port to the same startup lock key
- lock key canonicalization keeps IPv6 loopback `::1` separate from IPv4 loopback
- `http://127.0.0.1:8080/v1` is loopback but not autostartable; it should be treated as user-managed because of the non-empty base path
- `https://example.com/v1` fails as non-local
- `http://192.168.1.10:8080` fails as non-local

- [ ] **Step 2: Implement public helper**

Expose a small API such as:

```zig
pub const LocalEndpoint = struct {
    host: []const u8,
    port: u16,
    lock_key: []const u8,
    autostartable: bool,
};

pub fn localEndpoint(server_url: []const u8) !LocalEndpoint
```

Keep `parseHttpUrl` private if possible; only expose the minimal shape needed by runtime startup.

- [ ] **Step 3: Make HTTP timeout real**

`src/llama.zig` currently receives `timeout_sec` but does not enforce it. Add a bounded connect/read/write path for every HTTP request before relying on `server_startup_timeout_sec`:

- Either set socket receive/send/connect deadlines using platform APIs already available through libc/posix, or make the health probe nonblocking/poll-based.
- `healthCheck` must never block longer than its `timeout_sec`.
- `translateSegment` and its `/v1/chat/completions` POST must also never block longer than `timeout_sec`; do not only fix `/health`.
- `runtime.ensureServer` must use short bounded health probes inside its outer startup deadline.
- Add a testable seam for timeout behavior; do not require a public network server in unit tests.

- [ ] **Step 4: Verify**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/llama.zig
git commit -m "refactor: bound local llama health checks"
```

## Task 3: Runtime Manager

**Files:**
- Create: `src/runtime.zig`
- Modify: `src/errors.zig`
- Modify: `src/sys.zig`
- Modify: `src/main.zig`
- Test: `src/runtime.zig`

- [ ] **Step 1: Write pure tests for startup argument construction**

Test a function equivalent to:

```zig
buildLlamaServerArgv(allocator, cfg, endpoint)
```

Expected argv:

```text
<llama_server_path> -m <model_path> --host <host> --port <port>
```

Use no shell parsing and no shell invocation. Arguments must be passed as argv entries to avoid quoting issues.

- [ ] **Step 2: Add executable resolver tests**

Implement and test one shared resolver used by both `doctor` and `ensureServer`, for example:

```zig
pub fn resolveExecutable(allocator: std.mem.Allocator, configured_path: []const u8) ![]const u8
```

Test cases:

- absolute executable path exists -> returns that path
- relative path with a slash such as `./bin/llama-server` or `../llama-server` -> treats it as a direct path relative to the current working directory and does not search `PATH`
- relative or bare name exists in a temp `PATH` entry -> returns the resolved path
- bare name missing from `PATH` -> returns `ServerStartFailed`
- non-executable file exists -> returns `ServerStartFailed` if executable permission can be checked on the target platform

Resolution rule:

- If `llama_server_path` is absolute, validate that path directly.
- If it contains `/`, validate it as a direct relative path; do not perform `PATH` lookup.
- If it has no slash, search `PATH` explicitly.

Do not depend on `std.process.Child` implicit PATH behavior for correctness.

- [ ] **Step 3: Add error codes**

Add to `errors.Code`, `errors.Error`, and `errors.fromError`:

- `server_start_failed`
- `server_startup_timeout`

Messages should mention `llama_server_path`, `model_path`, and `kotoba doctor` in human-readable guidance.

- [ ] **Step 4: Implement runtime manager API**

Implement a shape like:

```zig
pub const ManagedServer = struct {
    child: ?std.process.Child,
    startup_lock: ?StartupLock,

    pub fn close(self: *ManagedServer) void {
        // terminate only children started by this invocation,
        // wait with a bounded grace period, force-kill on timeout,
        // and release any startup lock owned by this handle
    }
};

pub fn ensureServer(
    allocator: std.mem.Allocator,
    paths: xdg.Paths,
    cfg: config.Config,
    allow_remote_server: bool,
) !ManagedServer
```

Behavior:

- Validate local URL first.
- Use `paths.state_dir` or `paths.cache_dir` as the parent for endpoint-specific startup locks and runtime metadata. If `xdg.Paths` does not yet expose the needed directory directly, extend `src/xdg.zig` in the same task instead of hardcoding `/tmp`.
- Ensure the lock/metadata parent directories exist inside `ensureServer` before acquiring locks. Do not rely only on `kotoba init` calling `xdg.ensureDirs`; `translate` may be the first command that needs runtime metadata after config was created elsewhere.
- Autostart loopback validation must not call `validateLocalServerUrl(server_url, allow_remote_server)` because that API intentionally allows remote endpoints when the user opts in. Add a separate helper such as `llama.requireLoopbackEndpoint(server_url)` or `llama.localEndpointForAutostart(server_url)` that rejects remote URLs regardless of `allow_remote_server`.
- `ensureServer` should implement this routing in this order:
  - loopback endpoint: perform health check and autostart if needed, regardless of whether `allow_remote_server` is true,
  - loopback endpoint with a non-empty base path: do not autostart; if `/health` fails, return `ServerUnreachable` with user-managed endpoint guidance,
  - non-loopback endpoint with `allow_remote_server=true`: return a no-child/no-lock handle and let the normal HTTP request use the configured endpoint,
  - non-loopback endpoint with `allow_remote_server=false`: return `ServerNotLocal`.
- Apply the `runtime != "llama_server"` guard only after selecting the loopback/autostart path. It must not block the non-loopback remote passthrough case when `allow_remote_server=true`.
- Return `ServerUnreachable` without spawning if a loopback endpoint needs autostart but `runtime` is not `llama_server`.
- If `llama.healthCheck` succeeds, return a handle with no child.
- If health fails and autostart is disabled, return `ServerUnreachable`.
- If `model_path` is empty or missing, return `ModelMissing` with a clear message.
- Resolve `llama_server_path` with the shared resolver only after the initial `/health` check fails and autostart is actually needed. A missing or unexecutable binary must not break `translate` when an already-running local server is healthy.
- Coordinate startup with an atomic lock file under the Kotoba state/cache directory, or an equivalent per-endpoint lock.
- Lock file names must use the canonical `LocalEndpoint.lock_key`, not the raw `server_url`, so equivalent loopback URLs such as `localhost:8080` and `127.0.0.1:8080` coordinate through the same lock.
- The lock must be held from the second `/health` probe through successful readiness or startup failure cleanup. Do not release it immediately after spawning, because a second process can otherwise spawn another server while the first one is still loading the model.
- The lock must be owned by `ManagedServer` after acquisition. `ManagedServer.close()` must release it after readiness success/failure cleanup, and only the owner handle may release it.
- The lock must record enough owner metadata for stale recovery, such as pid, owner start time or another process-unique token, endpoint, and created timestamp. On lock acquisition failure, first revalidate `/health`; if no server is healthy and the recorded owner is definitely dead, recover the lock immediately. Use the age threshold only for ambiguous cases where owner liveness cannot be determined.
- PID reuse must not cause an active owner to be mistaken for a stale lock. If the platform cannot verify owner start time or an equivalent token, treat pid-only liveness as ambiguous and rely on the stale-age path after a failed `/health` recheck.
- Use a deterministic stale-lock policy for ambiguous cases: default stale threshold is `max(server_startup_timeout_sec * 2, 60)` seconds, and the implementation exposes a tiny clock/age seam for unit tests so stale recovery tests do not sleep in real time.
- While holding the lock, re-run `/health` before spawning so concurrent invocations can reuse a server that another process just started.
- If spawn fails because another process won the race and bound the port first, re-probe `/health` before returning `ServerStartFailed`.
- Spawn child with the resolved executable path, `-m`, `model_path`, `--host`, `host`, `--port`, `port`.
- Redirect child stdout/stderr to a controlled destination. Prefer stderr inheritance only while developing; final behavior should avoid noisy normal output.
- Poll `/health` every 200ms until `server_startup_timeout_sec`.
- On timeout or start failure, kill/wait child before returning.

- [ ] **Step 5: Add cleanup for normal and interrupted exits**

`defer managed_server.close()` handles normal error paths, but not external interruption. Implement and test actual Ctrl-C/SIGTERM cleanup on the supported POSIX target:

- Prepare signal ownership before spawn, for example by installing handlers before spawning and registering the managed child immediately after successful spawn while signals are temporarily blocked or otherwise guarded. Avoid a window where the child exists but the handler cannot find it.
- Start the child in its own process group/session where supported.
- On SIGINT/SIGTERM, terminate and wait the managed child or child process group with a short grace timeout, then force-kill and wait again before exiting.
- `ManagedServer.close()` must use the same bounded terminate -> grace wait -> force-kill -> final wait sequence, so normal exit cannot hang forever on a signal-ignoring child.
- Add a smoke or integration check that starts a fake long-running server through Kotoba, sends SIGTERM or SIGINT to Kotoba, and asserts the fake server is gone.
- Document only the remaining unavoidable limitation: SIGKILL and hard process crashes can orphan the child unless a later persistent supervisor/daemon design is added.

Do not kill a server that was already running before this Kotoba invocation.

- [ ] **Step 6: Add `std.testing.refAllDecls(runtime)`**

Modify `src/main.zig` so unit tests compile the new module.

- [ ] **Step 7: Verify**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/runtime.zig src/errors.zig src/sys.zig src/main.zig
git commit -m "feat: manage local llama server process"
```

## Task 4: Wire Translation and Init

**Files:**
- Modify: `src/translate.zig`
- Modify: `src/cli.zig`
- Test: existing integration smoke test after Task 5

- [ ] **Step 1: Wire `translate.run`**

Extend `translate.run` so it can receive `xdg.Paths` or a focused runtime path struct instead of only `xdg_memory_path`. At the start of `translate.run`, replace the standalone local URL validation with:

```zig
var managed_server = try runtime.ensureServer(allocator, paths, cfg, opts.allow_remote_server);
defer managed_server.close();
```

Important constraints:

- Start once per `translate` command.
- Keep memory hits working. It is acceptable to start before knowing whether every segment is cached for the first implementation. A later optimization can skip startup for full-cache hits.
- Preserve remote rejection behavior.
- Preserve unsupported runtime behavior. If `runtime` is not `llama_server`, do not autostart; surface the same server-unreachable style error unless a future runtime adapter is implemented.

- [ ] **Step 2: Wire `init`**

In `runInit`, after config and memory setup:

- If `server_autostart` is enabled and `model_path` exists, call `runtime.ensureServer`.
- Build the new init config by loading the existing config first when it exists, then applying explicit init arguments (`server_url`, `model_id`, `model_path`, etc.). Do not reset `server_autostart`, `llama_server_path`, `server_startup_timeout_sec`, or `runtime` back to defaults during `init`.
- Keep the returned `ManagedServer` alive until the init test translation is complete, then `defer close()`.
- If startup succeeds, keep the current test translation.
- `init` exit-code behavior must remain non-breaking:
  - Missing or empty `model_path` with `--yes --skip-download`: write config, print a warning, and exit 0.
  - Missing configured model file when a model path was supplied: keep the existing model-path validation semantics; do not add a new autostart-only hard failure.
  - `server_autostart=false` with no running local server: write config, print the existing start-server warning, and exit 0. It should behave like the current user-managed-server flow.
  - `runtime != "llama_server"` with no running local server: write config, print a warning that the configured runtime cannot be autostarted yet, and exit 0. Do not make init a hard failure for future runtime names.
  - loopback `server_url` with non-empty base path and no running server: write config, print a user-managed endpoint warning, and exit 0.
  - Missing/unexecutable `llama_server_path`: write config, print a warning that translation will fail until the binary is fixed, and exit 0.
  - Startup timeout or failed readiness: write config, print a warning with `kotoba doctor`, and exit 0.
- For `translate`, keep missing/unexecutable `llama_server_path` as a hard `server_start_failed` error because the command cannot complete.
- That hard `server_start_failed` applies only when `translate` actually needs to autostart. If `/health` succeeds against an already-running local server, `translate` must not resolve or require `llama_server_path`.

- [ ] **Step 3: Keep explicit remote behavior**

For a non-loopback `server_url` with `--allow-remote-server`, do not autostart and continue to use the configured endpoint. For a loopback `server_url`, `--allow-remote-server` must not suppress autostart.

Add tests for:

- non-loopback without `--allow-remote-server` -> `server_not_local`,
- non-loopback with `--allow-remote-server` -> no autostart attempt and request goes to the configured endpoint,
- loopback with `--allow-remote-server` -> autostart still works when no server is running.

- [ ] **Step 4: Verify unit tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/translate.zig src/cli.zig
git commit -m "feat: autostart llama server for translations"
```

## Task 5: Integration Test Autostart

**Files:**
- Modify: `test/integration/fake_llama_server.py`
- Modify: `test/integration/smoke.sh`

- [ ] **Step 1: Extend fake server CLI compatibility**

Allow the fake server to accept either:

```bash
fake_llama_server.py 18080
```

or llama-server-style flags:

```bash
fake_llama_server.py -m /tmp/model.gguf --host 127.0.0.1 --port 18080
```

- [ ] **Step 2: Create a fake `llama-server` wrapper in smoke test**

Split `test/integration/smoke.sh` into explicit phases:

- Manual-server compatibility phase: keep the existing direct translation/stdin/file/json assertions with a manually started fake server, because those flows validate translation behavior independent of autostart.
- Autostart phase: use fresh temp XDG directories and fresh ports, remove the top-level manual fake-server launch from this phase, and require that no process is listening before each autostart command. The only fake server process in this phase should be spawned through the wrapper below.

Create `${TMP}/bin/llama-server` that execs the fake server. Do not export this wrapper globally for the whole smoke script; scope it to the cases that are supposed to autostart, or configure it via absolute `llama_server_path` only after the warning-only init case has run.

```bash
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/llama-server" <<SH
#!/usr/bin/env bash
exec python3 "${ROOT}/test/integration/fake_llama_server.py" "\$@"
SH
chmod +x "${TMP}/bin/llama-server"
```

When a case intentionally tests bare-name PATH resolution, set PATH only for that command or subshell:

```bash
export PATH="${TMP}/bin:${PATH}"
```

Do not manually start the fake server at the top of the autostart smoke cases.

- [ ] **Step 3: Configure Kotoba to use the fake binary when needed**

After `init`, or through generated config, ensure:

```bash
kotoba config set llama_server_path "${TMP}/bin/llama-server"
kotoba config set server_startup_timeout_sec 5
```

Also assert the config command path:

```bash
"${ROOT}/zig-out/bin/kotoba" config set llama_server_path "${TMP}/bin/llama-server"
[[ "$("${ROOT}/zig-out/bin/kotoba" config get llama_server_path)" == "${TMP}/bin/llama-server" ]]
"${ROOT}/zig-out/bin/kotoba" config set server_startup_timeout_sec 5
[[ "$("${ROOT}/zig-out/bin/kotoba" config get server_startup_timeout_sec)" == "5" ]]
"${ROOT}/zig-out/bin/kotoba" config set server_autostart true
[[ "$("${ROOT}/zig-out/bin/kotoba" config get server_autostart)" == "true" ]]
```

- [ ] **Step 4: Split init and translate autostart cases**

Use separate temp XDG directories and ports for deterministic coverage:

- Case A: `init` with an existing model path and fake `llama-server` path may autostart, run test translation, then exit. Assert the port is not reachable after `init` exits, proving cleanup.
- Case B: isolate translate-triggered autostart. Run `init --yes --skip-download --model-path <valid path>` with no server running and before the fake wrapper is on `PATH` or configured. To make this deterministic even on machines that have a real `llama-server` installed, run that init with `PATH` fixed to a temp directory that intentionally does not contain `llama-server`, or pre-seed config with `llama_server_path=<known-missing absolute path>`. Then configure `server_autostart=true`, `llama_server_path=<absolute fake binary>`, and `server_startup_timeout_sec=5`. The first `translate` must autostart. Assert the port is free before translate and not reachable after translate exits.

- [ ] **Step 5: Assert process is started and cleaned up by Kotoba**

Before each autostart command, deterministically verify no server is reachable on `${PORT}` using a bounded local probe.
For every autostart case, assert that Kotoba actually exercised the started fake server, not only the warning-and-exit-0 fallback:

- make the fake server append its pid, argv, endpoint, `/health`, and `/v1/chat/completions` events to a temp log,
- assert each autostart case produced exactly the expected spawn marker,
- for Case A, also require `init` stdout to include `initialized`, which only happens after the test translation succeeds,
- for Case B, assert the first `translate` output is `JA:Hello` and the fake log contains both `/health` and `/v1/chat/completions`.

Then run:

```bash
"${ROOT}/zig-out/bin/kotoba" translate "Hello" --to ja
```

Expected: `JA:Hello`.

After each autostart command exits, verify the port is no longer reachable so leaked child processes are caught. This must poll until a short cleanup timeout instead of checking once immediately, so normal child shutdown latency does not make the test flaky.

- [ ] **Step 6: Preserve remote rejection coverage**

Keep the existing `server_not_local` test. It must not attempt autostart for `http://192.0.2.1:8080`.

- [ ] **Step 7: Verify**

Run:

```bash
zig build
test/integration/smoke.sh
```

Expected: `smoke ok`.

- [ ] **Step 8: Add deterministic timeout and interruption coverage**

Add deterministic timeout fixtures for both request phases:

- a stalled-health mode that accepts a connection and never responds to `/health`, or delays `/health` beyond the configured timeout,
- a stalled-completion mode that answers `/health` but never responds to `/v1/chat/completions`.

Assertions:

- `kotoba doctor` or a focused integration command returns within the configured timeout plus a small margin.
- A translation command against the stalled completion mode sets `timeout_sec` to a short test value, uses `--no-memory` or a unique uncached input, and returns within `timeout_sec` plus a small margin.
- The error path is `server_unreachable`, `server_startup_timeout`, or `timeout`, not a hang.

Add an interruption cleanup assertion:

- start `kotoba translate` against a fake server mode that stays alive long enough for the test to signal Kotoba,
- make the fake server write its pid or a startup marker to a temp file so the test proves Kotoba actually spawned the child,
- assert that the marker appears after Kotoba starts and before the signal is sent,
- send SIGTERM or SIGINT to the Kotoba process,
- poll until the fake server port is closed and the recorded child pid is no longer alive,
- fail if the child remains reachable or alive after the cleanup timeout.

- [ ] **Step 9: Add lock and warning-contract regression tests**

Add deterministic tests for startup coordination:

- Stale lock recovery: create an endpoint lock file with a nonexistent owner pid, ensure a command revalidates `/health`, removes/recovers it immediately, autostarts successfully, and leaves no stale lock behind.
- Stale lock clock seam: use the runtime's test clock/age seam to mark the lock stale without sleeping; do not depend on wall-clock delays in CI.
- Concurrent startup: launch two Kotoba translate commands against the same temp XDG config and endpoint while the fake server delays readiness. Assert both commands complete successfully and the fake server's spawn log shows exactly one child process for that endpoint.
- Bind-race fallback: if practical, simulate a fake server binding during the race window and assert Kotoba re-probes `/health` instead of failing.

Add non-breaking `init` contract tests:

- missing/unexecutable `llama_server_path` during `init` exits 0 with a warning and written config,
- readiness timeout during `init` exits 0 with a warning and written config,
- `server_autostart=false` with no running server during `init` exits 0 with the existing start-server warning and written config,
- unsupported `runtime` with no running server during `init` exits 0 with a warning and written config,
- existing config values for `runtime`, `server_autostart`, `llama_server_path`, and `server_startup_timeout_sec` survive a later `init` unless the user explicitly changes them,
- loopback `server_url` with a non-empty base path is treated as user-managed and does not autostart,
- the same missing/unexecutable binary during `translate` without an already-running server fails with `server_start_failed`.
- an already-running healthy local server is reused by `translate` even if `llama_server_path` is missing or invalid.

Add `doctor` non-mutating checks:

- with autostart enabled and no server running, `kotoba doctor` reports runtime/autostart information but does not start the fake server; assert the fake server spawn log stays empty and the port remains closed.
- with invalid `models.toml` but valid `config.toml`, `doctor` still reports loaded config's `runtime`, `llama_server_path`, and `server_autostart` before/alongside the models error.

- [ ] **Step 10: Commit**

```bash
git add test/integration/fake_llama_server.py test/integration/smoke.sh
git commit -m "test: cover llama server autostart"
```

## Task 6: Doctor and Documentation

**Files:**
- Modify: `src/doctor.zig`
- Modify: `README.md`
- Modify: `docs/llama-server.md`
- Modify: `docs/privacy.md`
- Modify: `docs/design-v1.md`

- [ ] **Step 1: Add doctor runtime checks**

Add checks:

- `runtime`: `ok` when `runtime = "llama_server"`, warn/error for unsupported runtime.
- `llama_server_path`: `ok` if the shared runtime resolver can resolve it; `warn` if not found or not executable.
- `server_autostart`: `ok` or `warn` depending on config.

Do not start `llama-server` during normal `doctor`.
Run these runtime/config checks as early as possible after config parsing, before model loading and before server health. Remove the existing `models.load` failure short-circuit or move it after runtime checks. `doctor` must still report `runtime`, `llama_server_path`, and `server_autostart` when the server is down or `models.toml` is invalid, because that is the main diagnostic case for this feature.

If `config.toml` is missing or invalid, `doctor` cannot know user-specific runtime settings. In that case it should still print the existing `config` failure and may optionally print default runtime/autostart assumptions clearly labelled as defaults. Do not hide a valid loaded config's runtime checks behind later failures.

If `runtime` is unsupported, `doctor` should report that as a warning/error but continue printing `llama_server_path`, `server_autostart`, model, server, memory, glossary, and privacy checks where they are still meaningful. Unsupported runtime must not short-circuit the rest of the diagnostics.

- [ ] **Step 2: Update README quickstart**

Change the setup flow from "start server first" to:

```bash
kotoba init --model-id custom --model-path /path/to/model.gguf --yes --skip-download
kotoba translate "Hello world" --to ja
```

State the translation-time prerequisite directly: for the first `kotoba translate` to autostart a server, `llama-server` must be installed and discoverable on `PATH`, or `llama_server_path` must point to the executable. `kotoba init` itself may still write config with a warning when the runtime is not currently startable.

Mention manual server start remains supported when a server is already listening at `server_url`.

- [ ] **Step 3: Update llama-server docs**

Document:

- autostart defaults
- required `llama-server` binary availability
- config keys
- non-root/base-path `server_url` values are treated as user-managed endpoints and are not autostarted
- current process lifetime: per Kotoba invocation
- manual server mode for users who want persistent model loading

- [ ] **Step 4: Update privacy/design docs**

State that autostart is local-loopback only and does not weaken the remote endpoint opt-in rule.

- [ ] **Step 5: Verify**

Run:

```bash
zig build test
zig build
test/integration/smoke.sh
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/doctor.zig README.md docs/llama-server.md docs/privacy.md docs/design-v1.md
git commit -m "docs: document managed llama server startup"
```

## Rollout Notes

- This plan intentionally implements per-command child process lifetime first. A persistent daemon would need PID files, stale process handling, log files, and cross-platform process-group behavior; keep that out of the first implementation.
- Normal command exit and handled SIGINT/SIGTERM should terminate only the child process started by the current Kotoba invocation. SIGKILL and hard process crashes may still leave a child behind unless a later persistent supervisor/daemon design is added.
- Startup can be slow for large GGUF files. `server_startup_timeout_sec` must be user-configurable and documented.
- If a user already runs `llama-server`, Kotoba should detect it via `/health` and avoid starting a duplicate process.
- Concurrent Kotoba invocations should coordinate startup with a lock held through readiness and a second health probe before spawning. A bind failure after spawn should trigger one more health probe before surfacing a startup error.
- Startup locks must use atomic acquisition and stale-owner recovery so a crashed Kotoba process cannot block future starts forever.
- Autostart must be disabled for remote/non-loopback endpoints to preserve the existing privacy boundary.

## Final Verification Checklist

- [ ] `zig build test` passes.
- [ ] `zig build` passes.
- [ ] `test/integration/smoke.sh` passes without manually starting the fake server.
- [ ] `kotoba translate "Hello" --to ja` starts local `llama-server` when configured with a real model path and no server is running.
- [ ] `kotoba translate` reuses an already-running local server.
- [ ] `kotoba translate` rejects non-loopback `server_url` by default with `server_not_local`.
- [ ] `kotoba doctor` reports runtime/autostart state without starting a server.
- [ ] `kotoba doctor` remains non-mutating: it does not start `llama-server`, and invalid `models.toml` does not hide loaded runtime/autostart config checks.
- [ ] Startup timeout is bounded by real socket/read deadlines; a half-open or nonresponsive local endpoint cannot hang indefinitely.
- [ ] Stalled-server fixtures prove both `/health` and `/v1/chat/completions` timeout paths return within bounded time.
- [ ] New config keys pass both TOML round-trip and CLI `config set/get` checks.
- [ ] Autostart smoke tests assert both startup and post-command cleanup.
- [ ] SIGINT/SIGTERM cleanup is tested and only terminates children started by the current Kotoba invocation.
- [ ] Stale startup locks are recovered deterministically.
- [ ] Stale lock recovery is safe against PID reuse, using owner start time or an equivalent token when available.
- [ ] Concurrent Kotoba invocations against one endpoint spawn at most one managed fake server.
- [ ] `init` warning-only autostart failures keep the expected exit-0 setup behavior, while `translate` still hard-fails when it cannot autostart and no server is already running.
- [ ] `ManagedServer.close()` and SIGINT/SIGTERM cleanup cannot hang indefinitely on a child that ignores graceful termination.
