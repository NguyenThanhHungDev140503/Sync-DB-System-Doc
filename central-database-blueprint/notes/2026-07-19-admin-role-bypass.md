# Admin Role Bypass — Temporary

**Date:** 2026-07-19
**Context:** Central DB Sync Phase 1 Pilot manual testing

## Status

The `AppConst.Admin` role check on `POST /api/central-db-sync/bootstrap/{sourceTable}`
is **temporarily disabled** for Phase 1 pilot testing.

## Reason

- The test account `manager@ua` does not have the Admin role in the dev database
- Creating an Admin user for testing requires additional identity/permission setup
- To unblock manual testing during Phase 1 pilot, the role guard has been commented out

## Re-enable before UAT/Production

In file `WebApi/Controllers/CentralDbSyncController.cs`, search for the TODO comment
and uncomment the role check before deploying to UAT or Production:

```csharp
// TODO: Re-enable before UAT — admin check temporarily disabled for Phase 1 pilot
// if (!HttpContext.User.IsInRole(AppConst.Admin))
//     return Forbid();
```

## Risk

Without the Admin guard, any authenticated user (with a valid JWT) can trigger
a full bootstrap, which overwrites the entire target table in PostgreSQL.
This is acceptable for the dev/Phase 1 environment only.
