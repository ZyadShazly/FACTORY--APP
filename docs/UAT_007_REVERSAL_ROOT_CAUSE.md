# UAT-007 — Reversal and cancellation root-cause analysis

## Scope

This note covers the UAT failures where sale cancellation and production-order cancellation opened a browser confirmation flow, then appeared to remain pending without a reliable final result.

## Confirmed findings

1. Multiple production flows still depend on browser-native `window.prompt` / `window.confirm`, including sales, rentals, production, project budget/cost, materials, opening inventory, and catalog flows.
2. Sales and rental cancellation already call protected RPCs and preserve history rather than deleting posted records.
3. Production cancellation already calls `cancel_production_order` and is intended to reverse eligible material movements without erasing history.
4. The shared `syncMutation` helper waits for a refetch after the RPC, but it has no timeout, no explicit server-state verification predicate, no retry contract, and no idempotency key. A successful mutation followed by a stalled/failed refetch can therefore look like a permanently pending operation to the user.
5. Several flows expose no operation-specific busy state around the native prompt/confirm sequence, so double clicks and repeated submissions are not consistently prevented.

## Root cause

UAT-007 is not one isolated delete bug. It is a cross-cutting transaction-finalization defect caused by four gaps working together:

- browser-native confirmation dialogs outside the application state model;
- incomplete busy/deduplication handling;
- mutation success being inferred from a follow-up refetch rather than verified against the authoritative server state;
- no bounded timeout/retry and no idempotency token for reversal commands.

## Required implementation

1. Replace native dialogs in release-blocking transaction flows with one reusable in-app confirmation component.
2. Require a reason where the server contract requires one and keep the confirmation button disabled until valid.
3. Assign an operation-specific busy key and disable all duplicate actions until completion.
4. Add a bounded RPC timeout and a separately bounded refetch timeout.
5. After the RPC returns, verify the authoritative row state (`cancelled`, `reversed`, returned stock, excluded totals) before showing success.
6. If mutation succeeds but refresh fails, show: “The operation was saved, but the screen could not refresh” and provide a safe retry that does not resubmit the mutation.
7. Add an idempotency key or server-side already-cancelled guard so repeated calls return the existing final result instead of applying a second reversal.
8. Log command id, actor, reason, source status, final status, and reversal references in the audit trail.
9. Add regression coverage for success, validation failure, network timeout before response, response lost after commit, duplicate click, retry after refresh failure, already-cancelled record, and partial reversal failure.

## Data safety

- No posted sale, rental, production order, or inventory movement should be hard-deleted.
- Existing UAT anomalies must be cancelled/reversed through the protected workflow, not rewritten directly.
- Any database change must be additive and must not be applied to production without owner approval.

## Current status

Root cause confirmed. Implementation pending. No merge or production migration authorized.
