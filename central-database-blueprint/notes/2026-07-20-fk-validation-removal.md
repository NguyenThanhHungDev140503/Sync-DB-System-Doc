# FK validation removed from `sync_meta.bootstrap_request`

**Date:** 2026-07-20

## What

The `REFERENCES sync_meta.table_sync_config(source_table)` foreign key constraint was removed from `sync_meta.bootstrap_request.source_table` (`001-central-db-sync-schema.sql`, section 6).

## Why

- DB-level FK makes schema migrations fragile (table creation order matters, can't clean up configs independently).
- The application layer already validates table names — currently via `RegisteredTables` hardcoded set in `CentralDbSyncController.cs`.

The safety net is now purely in application code.

## Future — Phase 2+

The current `RegisteredTables` in the controller is a hardcoded set (`"CRM.Partners"`). This is a temporary approach. Future phases should:

1. Create a store/service to query `sync_meta.table_sync_config` from the database at runtime.
2. Inject that service into both the controller (for `TriggerBootstrap`) and the `BootstrapRequestService` (for defense-in-depth in case the endpoint is called from non-controller paths).
3. Remove the hardcoded `RegisteredTables` and replace it with the live DB query.
