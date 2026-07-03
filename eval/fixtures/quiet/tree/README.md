# metrix

Usage metering and billing for tenant events.

## Modules

- `metrix/api.py` — login endpoint
- `metrix/storage.py` — sqlite-backed event storage
- `metrix/auth.py` — bearer-token auth for the metering endpoints
- `metrix/worker.py` — background summary shipping
- `metrix/cli.py` — usage report CLI

## Usage report CLI

Generate a per-tenant usage report from the stored events:

```
python -m metrix.cli acme-corp --since 2024-01-01
```

By default the report prints as plain text. Pass `--format json` to get
machine-readable output for piping into other tools:

```
python -m metrix.cli acme-corp --format json
```
