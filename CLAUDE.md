# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`c8y-dtm` is a [go-c8y-cli](https://goc8y.netlify.app/) extension for Cumulocity IoT's Digital Twin Manager (DTM). It adds DTM-specific CLI commands to the `c8y` tool. Install via:

```bash
c8y extension install Cumulocity-IoT/c8y-dtm
```

No build step or compilation is needed — the extension is used as-is from the repository.

## Runtime Dependencies

- `c8y` (go-c8y-cli v2) — must be installed and authenticated against a Cumulocity tenant
- `jq` — JSON processor used throughout the Bash scripts

Both are checked at runtime by `check_prerequisites()` in `shared/helper`.

## Architecture

The extension uses two complementary patterns:

### 1. Declarative API Commands (YAML)

Files in `api/` define REST API wrappers that go-c8y-cli auto-generates into CLI commands:

- `api/assets.yaml` — Asset CRUD, sub-assets, device linkage, external ID lookup
- `api/linkedseries.yaml` — Linked series source management
- `api/settings.yaml` — DTM tenant settings

These YAML files follow the go-c8y-cli extension schema (`extension.json`). To add or modify API commands, edit these YAML files — no scripting required.

### 2. Imperative Bash Commands

Files in `commands/` are standalone Bash scripts for complex workflows:

- `commands/admin/latestvalue-option` — Manage tenant options for measurement.series.latestvalue
- `commands/migration/bootstrap-microservice` — Create microservice app and retrieve service user credentials
- `commands/migration/externalids-check` — Verify external ID consistency (detects 11 error types)
- `commands/migration/externalids-clear` — Remove c8y_ExternalId fragments and external identities
- `commands/migration/externalids-create` — Create external IDs from configurable templates (supports `--workers` for parallelism)
- `commands/migration/opposites` — Create/clear/verify opposite references for linked series
- `commands/migration/run-subtenants` — Run any command against all subtenants of a microservice

### Shared Utilities

`shared/constants` — Fragment name constants (`EXTERNAL_ID_FRAGMENT`, `EXTERNAL_ASSET_FRAGMENT`, `LINKED_SERIES_FRAGMENT`)

`shared/helper` — Sourced by all Bash scripts; provides:
- Logging: `warn()`, `error()`, `info()`, `success()` with ANSI color
- Argument validation: `validate_positional_args()`, `has_flag()`
- Template processing: `extract_template_properties()`, `init_template_properties_array()`
- Asset loading with filtering: `load_all_assets()`
- Duplicate detection: `get_duplicate_external_ids()`

Every Bash command script sources `shared/helper` at startup (via a relative path from the script's own location) and calls `check_prerequisites` early.

## Key Patterns

**NDJSON pipeline**: All commands accept NDJSON on stdin and emit NDJSON on stdout, making them composable with Unix pipes and other `c8y` commands.

**Template-based ID generation**: `externalids-create` uses property placeholders (e.g. `{{fragment.property}}`) in a configurable template string to generate external IDs from asset data.

**Parallel execution**: Migration commands accept `--workers N` to process assets concurrently using `c8y`'s built-in worker support.

**Hidden shared group**: The `_shared` group in `extension.yaml` is intentionally hidden from help and autocompletion — it holds internal shared definitions, not user-facing commands.
