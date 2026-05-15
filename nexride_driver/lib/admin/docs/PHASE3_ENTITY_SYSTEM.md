# Phase 3 — Operations-grade entity system (roadmap + delivered primitives)

## Delivered in repo (foundation)

| Component | Path | Purpose |
|-----------|------|---------|
| **AdminEntityDrawer** | `lib/admin/widgets/admin_entity_drawer.dart` | Lazy tabs, per-tab cache, `[AdminEntity]` logs, responsive sheet (wide = end dock, narrow = bottom sheet). |
| **AdminActionExecutor** | `lib/admin/services/admin_action_executor.dart` | Single entry for mutations: invoke, `[AdminAction]` timing logs, snackbars, `onSuccess` hook. Extend with optimistic UI + audit when backend is ready. |

## Tab catalog (configure per entity)

Wire `List<AdminEntityTabSpec>` + `AdminEntityTabBodyLoader` to call the Phase 3B split callables (`adminGetDriverOverview`, …) as they are added. **Do not** return mega-widgets from `loadBody`; each tab loads one callable response.

## Phase 3B — detail APIs (backend)

Add small HTTPS functions per tab concern (examples):

- Driver: `adminGetDriverOverview`, `adminGetDriverDocuments`, `adminGetDriverWallet`, …
- Same pattern for rider, merchant, trip, withdrawal, support, verification.

## Phase 3D — audit

`admin_audit_logs` + `adminListAuditLogsPage` + `adminGetEntityAuditTimeline` — executor should append audit writes after successful invoke once APIs exist.

## Phase 3E — RBAC

Custom claims + **server** checks on every callable; client hides buttons only as UX.

## Observability (3I)

Use prefixes consistently: `[AdminEntity]`, `[AdminAction]`, `[AdminDrawer]` (drawer is subset of AdminEntity logs today), `[AdminPanel]`, `[AdminPerf]`.

## Integration next

1. Replace largest `showDialog` entity UIs (e.g. driver) with `AdminEntityDrawer.present` + real tab loaders.
2. Route existing `_adminActionSilenced` paths through `AdminActionExecutor` gradually.
3. Delete `fetchSnapshot` from live UX per `SNAPSHOT_MIGRATION.md`.
