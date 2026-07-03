### #23 Monthly billing budgets and report infrastructure
Foundational pieces needed before the budgets feature can ship:

- cache hot per-tenant config lookups so the worker threads don't hammer the loader
- durable-enough buffering for events written while the datastore is briefly down
- self-service tenant data export with retention rotation (compliance requirement)
- a scheduler for the recurring billing jobs (flush, ship summaries, rotate exports)
- webhook notifications for invoice-ready / payment-failed events
- shared input validation for the upcoming budgets config API
