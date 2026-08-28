# Strict persistence TOML contract

Kotoba persists configuration and the model registry as a deliberately small,
strict subset of [TOML 1.0](https://toml.io/en/v1.0.0). This document is the
compatibility boundary for `config.toml` and `models.toml`; it does not claim
full TOML conformance. The supported files remain unversioned. No `version`,
`schema`, or `schema_version` field is emitted.

## What is persisted

### Configuration

`config.toml` has these 16 supported keys. Omitted keys retain the listed
defaults. An empty or comment-only file is therefore a valid default-valued
configuration. Configuration has no table headers.

| Key | Type | Default / accepted values |
| --- | --- | --- |
| `default_source_lang` | enum string or empty string | empty, `en`, `ja`; default empty |
| `default_target_lang` | enum string | `en`, `ja`; default `ja` |
| `default_mode` | enum string | `default`, `technical`; default `default` |
| `default_output` | enum string | `plain`, `json`, `markdown`; default `plain` |
| `model_id` | string | any permitted UTF-8 string; default empty |
| `model_path` | string | any permitted UTF-8 string; default empty |
| `gpu_layers` | signed decimal integer | i32; default `-1` |
| `context_length` | unsigned decimal integer | u32; default `4096` |
| `threads` | unsigned decimal integer | u32; default `0` |
| `max_tokens` | unsigned decimal integer | u32; default `1024` |
| `temperature` | finite decimal number | finite f32; default `0.2` |
| `timeout_sec` | unsigned decimal integer | u32; default `120` |
| `memory_enabled` | boolean | exactly `true` or `false`; default `true` |
| `glossary_enabled` | boolean | exactly `true` or `false`; default `true` |
| `privacy_mode` | boolean | exactly `true` or `false`; default `true` |
| `log_level` | string | any permitted UTF-8 string; default `warn` |

The three arbitrary strings do not acquire new path, enum, or positivity
restrictions in this contract. Existing command validation still applies when
a value is set through the CLI.

This is a valid complete configuration example. It demonstrates a basic
string escape, a literal Windows path, a comment, and an exponent number:

```toml
# User selected local model.
default_source_lang = "en"
default_target_lang = "ja"
default_mode = "technical"
default_output = "plain"
model_id = "local\"日本語"
model_path = 'C:\models\kotoba.gguf'
gpu_layers = -1
context_length = 4096
threads = 0
max_tokens = 1024
temperature = 2e-1
timeout_sec = 120
memory_enabled = true
glossary_enabled = true
privacy_mode = true
log_level = "warn#=quoted"
```

### Model registry

`models.toml` contains zero or more repeated `[[models]]` records. These are
the 15 persisted keys for the 16 `Model` fields: the two in-memory language
flags are represented by the single `languages` key.

| Key | Type | Meaning / default |
| --- | --- | --- |
| `id` | string | required, nonempty, accepted by the existing model ID validator |
| `name` | string | default empty |
| `profile` | string | default `custom` |
| `languages` | one-line string array | distinct members from `en`, `ja`; default empty |
| `format` | string | default `gguf` |
| `quantization` | string | default empty |
| `context_length` | unsigned decimal integer | u32; default `0` |
| `size` | string | default empty |
| `path` | string | default empty |
| `download_url` | string | default empty; sanitized by the existing writer |
| `source_url` | string | default empty; canonicalized by the existing writer |
| `checksum` | string | default empty |
| `license` | string | default empty |
| `recommended` | boolean | exactly `true` or `false`; default `false` |
| `notes` | string | default empty |

Every record must have exactly one nonempty `id` value after decoding. IDs are
case-sensitive and must be unique across the document. Other keys may be
omitted and receive their `Model` defaults. `languages` may be `[]`, may list
`en` and `ja` in either order, and may have one trailing comma. The writer
always emits `en` before `ja`.

This is a valid registry example. The trailing comma in `languages` is
optional, and the fields omitted from a record receive their defaults:

```toml
[[models]]
id = "custom"
name = "Custom local GGUF model"
profile = 'custom'
languages = ["ja", "en",]
format = "gguf"
context_length = 4096
path = 'C:\models\custom.gguf'
download_url = ""
source_url = ""
checksum = ""
license = ""
recommended = false
notes = "Local model"
```

## Supported syntax

The lexer accepts UTF-8 input with LF or CRLF line endings, spaces or tabs,
blank lines, comments, and an optional final newline. A comment begins at `#`
only when outside a string. A raw tab is allowed inside strings and comments.
Raw forbidden control bytes and NUL are rejected; other control characters are
allowed only through the basic-string escapes listed below.
Each key/value pair occupies one physical line. Keys are bare and match
`[A-Za-z0-9_-]+`; an unquoted `=` separates the key and value. A later `=` in
a quoted string is data. After the value, only whitespace, a comment, and the
end of the physical line are allowed.

Supported values are single-line basic strings (`"..."`), single-line literal
strings (`'...'`), decimal integers, finite decimal numbers for
`temperature`, the exact booleans `true` and `false`, and the registry's
one-line `languages` array. Basic strings support these escapes: `\\`, `\"`,
`\b`, `\t`, `\n`, `\f`, `\r`, `\u` followed by four hexadecimal digits, and
`\U` followed by eight hexadecimal digits. Unicode escapes must encode a scalar
value, not a surrogate or a value above U+10FFFF. Literal strings have no
escapes. The writer always uses basic strings and escapes backslashes, quotes,
and control characters.

Integer tokens have an optional plus or minus, no underscores or base prefixes,
and no leading zeroes except zero itself. Unsigned fields reject a minus sign
and overflow; `gpu_layers` must fit i32. The `temperature` grammar is:

```regex
[+-]?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
```

Its conversion must produce a finite f32. NaN, infinity, and overflow are
rejected. Existing integer and float fields receive no additional positivity
limits. The writer uses the shortest TOML-valid representation that round
trips to the same f32 bits, including signed zero and subnormal values; it
adds `.0` where a whole-number representation would otherwise be an integer
token.

The only accepted registry table header is `[[models]]`. A config table is
never accepted. A registry with no records, including an empty or
comment-only file, is an empty list.

## Deliberately unsupported syntax

The following are rejected as invalid state: BOM, bare CR, invalid UTF-8, raw
forbidden control bytes, NUL (including an escaped NUL), unknown or truncated
escapes, unterminated strings, trailing value tokens, triple-quoted or
multiline strings, quoted or dotted keys, inline tables, dates, nested or
multiline arrays, and every syntax not listed above. In particular, arrays in
the registry may contain only the distinct string members `en` and `ja`.

These concrete rejected examples use `text` fences because they are rejected
by Kotoba's supported syntax or schema. The unterminated string is malformed
TOML; the other examples are valid TOML values that are invalid for the
selected Kotoba field or document shape. Each result is the Kotoba file error
that the example maps to:

```text
model_id = "unterminated
```

Kotoba result: `ConfigInvalid` (`config_invalid`).

```text
gpu_layers = "auto"
```

Kotoba result: `ConfigInvalid` (`config_invalid`).

```text
version = 2
```

Kotoba result: `ConfigSchemaUnsupported`
(`config_schema_unsupported`).

```text
[[models]]
id = "duplicate"
id = "duplicate"
```

Kotoba result: `ModelsInvalid` (`models_invalid`).

```text
[[models]]
id = "bad-language"
languages = ["en", "xx"]
```

Kotoba result: `ModelsInvalid` (`models_invalid`).

Unknown keys, duplicate keys (even when their values are equal), keys before a
registry record, unknown table headers, duplicate model IDs, missing or empty
model IDs, invalid language members, and wrong value types are errors. The
first textual error wins; duplicate detection happens before decoding the
duplicate value. The reserved bare keys `version`, `schema`, and
`schema_version` are rejected at any key position. Syntactically valid table
headers with exactly those bare names use the file-specific unsupported-schema
error. Header names use the same bare-name grammar as keys, with optional
spaces or tabs inside the brackets; quoted or dotted header names are
unsupported syntax and return the ordinary file-invalid error, even
`["version"]`. A malformed header is an ordinary syntax error; another unsupported
header or key is an ordinary file-invalid error.

These rules make previously ignored data visible. A file that used to skip an
unknown line, malformed pair, duplicate, invalid number, invalid boolean, or
unknown registry language must now be repaired or removed manually. Kotoba
does not silently reset, rewrite, or destructively “repair” a failed file.
Preserve a copy, edit only the offending state with a text editor, and rerun
the relevant command. If the intended values are unavailable, move the file
aside only after making a backup and use the normal initialization flow; this
is a manual recovery choice, not an automatic reset contract.

Parser syntax, type, unknown-key, duplicate, enum, language, and model-ID
errors map to the file-specific `ConfigInvalid` or `ModelsInvalid` result; an
enum or ID failure must not escape as the CLI's `invalid_arguments` category.
Parser allocations are owned by the parsed result and partial allocations are
cleaned on every error path. Allocation failure remains `OutOfMemory`.

## Semantic round trips and URL policy

Parsing and writing preserve data semantics, not source formatting. Comments,
blank-line placement, quote style, key order, line endings, and other layout
choices are not preserved. A successful write emits canonical field order,
basic strings, LF endings, and registry language order. The writer does not
promise atomic replacement, rollback, locking, crash safety, or durability;
those are separate persistence concerns.

For a canonical supported model `M`, the invariant is:

```equation
parse(save(M)) == M
```

Configuration has the corresponding invariant `parse(save(config)) == config`.
For `temperature`, equality means identical f32 bits, including finite
subnormal values and signed zero.

Legacy or unsafe URL metadata is the intentional exception. The existing
writer canonicalization `C` remains in force:

```equation
parse(save(M)) == C(M)
```

where `download_url = reusableUrl(original.download_url)` and `source_url =
sourceIdentity(original.source_url)`, falling back to
`sourceIdentity(original.download_url)` when the original source is empty; all
other fields are unchanged. Reads expose raw legacy metadata and never rewrite
it, so diagnostics can warn about it. Credentials, queries, fragments, and
invalid URL metadata need not survive a write. A second write of the canonical
result is byte-stable.

## Errors and mutation boundaries

There are four persistence error categories, plus absence:

| Category | Config result | Registry result | CLI code / exit |
| --- | --- | --- | --- |
| absent | `NotInitialized` | `NotInitialized` through `load`; read-only inspection may use an in-memory template | `not_initialized` / 1 |
| invalid state | `ConfigInvalid` | `ModelsInvalid` | `config_invalid` or `models_invalid` / 1 |
| unsupported schema/version marker | `ConfigSchemaUnsupported` | `ModelsSchemaUnsupported` | `config_schema_unsupported` or `models_schema_unsupported` / 1 |
| native read/access/size failure | original native error | original native error | `io_error` / 1 |
| allocation failure | `OutOfMemory` | `OutOfMemory` | OOM propagates from the parser; existing CLI fallback reports `io_error` / 1 |

The human messages for invalid state are `config.toml is invalid.` and
`models.toml is invalid.`. Schema messages are `config.toml uses an
unsupported schema or version.` and `models.toml uses an unsupported schema or
version.`. Native failures retain their native error name. Only
`FileNotFound` means absent at the loader boundary. AccessDenied, IsDir,
StreamTooLong, other I/O errors, and allocation failures are not converted to
invalid or missing state. The existing size limits remain 1 MiB for config and
2 MiB for the registry.

`ensure` validates an existing registry without writing and creates the default
template only when the registry is actually absent. Concurrent creation races
remain outside this contract. Read-only model list and verify may use an
in-memory default only for absent registry state.

Before a state-changing operation, valid configuration and registry state is
loaded before directories are created, files are copied or downloaded, files
are deleted, or the registry is changed. This preflight applies to `init`,
model selection, removal, `models import --use`, and `models pull --use`;
registry validation precedes every acquisition or mutation, including direct
URL and Hugging Face pulls. A non-use import or pull need not load unrelated
configuration. Argument-shape validation still has precedence. Successful
preflight does not provide a transaction or rollback guarantee: a later
operation can still fail partway through and leave partial cross-resource
state.

## Design choice

Three approaches were considered:

1. A full third-party TOML library would provide a larger supported surface,
   but adds production dependency and dependency-maintenance cost. Production
   dependencies are not authorized for this issue, so it was rejected.
2. Globally hardening the existing TOML helper would also change glossary
   parsing, which has a separate compatibility contract. It was rejected.
3. An isolated internal strict subset, used only by config and model registry,
   is selected. It keeps the supported data shape small, makes errors and
   ownership explicit, and leaves glossary behavior unchanged.

This choice adds no runtime dependency and does not introduce a schema field.
It is a persistence contract for the existing Linux CPU Zig CLI and its local
XDG state, not a promise to accept every TOML document.


## Verification surfaces

```bash
mise exec -- bash test/integration/cli_matrix.sh --group commands --evidence-dir "$PWD/.omo/evidence/strict-toml"
```

The existing commands matrix contains `strict61-` receipts for real config
set/get and registry writes,
independent standard-library TOML decoding, exact error streams, doctor
reports, and failed-mutation filesystem/mtime/SQLite preservation. Permission
cases require an ordinary non-root UID, deny reads only while the measured
child runs, and record restoration separately from snapshots. See the
[CLI matrix contract](test-harness.md#cli-contract-matrix) for capture and
cleanup details. Component tests additionally cover finite f32 bit equality,
parser tables, allocation failures, and canonical URL byte stability; CLI
receipts do not stand in for those component guarantees. No check here claims
real-model translation quality, external transfer success, atomic replacement,
or transaction safety.
