### #17 Monthly billing summary per tenant
The invoicing job needs a per-tenant monthly billing summary:

- total usage and per-kind cost in integer cents (invoices must never lose cents)
- paginated event listing for the dashboard (all events reachable)
- summaries shipped to the internal billing API from a background worker
- metering endpoints must accept the existing per-user API tokens

The worker will run with several threads, so shared state must be thread-safe.
