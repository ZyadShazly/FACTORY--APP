# EP-01 — Live Schema and Data Reconciliation

> **Status:** Draft evidence package
>
> **Snapshot date:** 2026-08-02
>
> **Repository baseline:** `8e7d9496d0f55060dae3f35a60d5d597d9bcd3b3`
>
> **Live project:** `FACTORY APP` / `ACTIVE_HEALTHY` / PostgreSQL 17

## Safety boundary

This package is based on read-only inspection. It does not update production
rows, apply migrations, delete records, or infer business meaning from names.
Any remediation must be delivered in a separate bounded migration or product
workflow with tests and a rollback path.

## Reconciliation result

| Area | Evidence | Decision |
| --- | --- | --- |
| Migration history | The live semantic migration names continue to match the repository-to-live map in `CURRENT_SYSTEM_STATUS.md`; generated live versions are expected. | Do not replay repository migrations merely because their numeric version is absent from live history. |
| Inventory classification | `inventory_items.item_type` and live migration `20260729082906 explicit_inventory_item_type` remain authoritative. | `stock_kind` remains rejected; PR #99 was closed without merge. |
| Purchase Request lifecycle | 14 live requests, 27 status-history rows, 0 orphan history rows, and 0 requests whose current status lacks a matching history entry. The live request table has approval/rejection timestamps but no `converted_at` or `completed_at`. | Immutable `purchase_request_status_history` is the canonical conversion/completion record. Do not replay the older timestamp-column migration. |
| Project lifecycle anomaly | One non-exempt project, code `AUTO`, is active/manufacturing with an execution timestamp and no project-approval timestamp. | Preserve the row. Do not fabricate approval evidence or silently mark it exempt. Route it through a controlled reconciliation action after the business reason is recorded. |
| Expense anomaly | One SAR 123 electricity expense dated 2026-07-14 has neither a project nor an Actual Cost entry and remains `not_posted`. | The two previous counts describe the same row. Do not auto-assign it to a project: EP-02 must explicitly support project expense versus general overhead and post/reverse accordingly. |

## Purchase Request lifecycle contract

The canonical lifecycle is:

`draft -> submitted -> approved|rejected -> converted -> completed`

The current live data contains `submitted`, `converted`, and `rejected`
requests. Every current state is represented in the immutable history table.
Therefore:

- `purchase_requests.status` is the current state;
- `purchase_request_status_history` is the transition audit trail;
- approval and rejection timestamps remain event evidence on the request;
- conversion and completion evidence belongs to history metadata and the linked
  Purchase Order / receipt records;
- repository migration
  `202607240001_procurement_request_lifecycle.sql` must not be applied blindly
  to production.

## Supabase Advisor classification

The 2026-08-02 Security Advisor snapshot reported:

| Finding | Count | Classification |
| --- | ---: | --- |
| RLS enabled with no policy | 38 | Mostly intentional RPC-only tables; verify table grants and RPC authorization before marking resolved. |
| Extension in `public` | 1 | Review `btree_gist` relocation separately; no live move without dependency inspection. |
| Anonymous executable SECURITY DEFINER functions | 5 | Four asset token/preview functions are intentionally public-link boundaries and require token-expiry/rate-limit UAT. `create_inventory_item_typed` is not an anonymous workflow and must lose anonymous/PUBLIC execution. |
| Authenticated executable SECURITY DEFINER functions | 167 | Not automatically a defect: these form the application's RPC boundary. Each must enforce `auth.uid()`, role checks, fixed `search_path`, and least-privilege grants. |
| Leaked-password protection disabled | 1 | Auth configuration hardening item; does not justify a schema migration. |

Advisor reference:
[Supabase database linter](https://supabase.com/docs/guides/database/database-linter).

### Confirmed ACL gap

Migration `202607290003_explicit_inventory_item_type.sql` grants
`create_inventory_item_typed` to `authenticated` but does not revoke the
Postgres default `PUBLIC` execute privilege. The function contains an internal
owner/manager check, which blocks useful anonymous execution, but the endpoint
should not be exposed to `anon` at all.

Required bounded remediation:

```sql
revoke execute on function
  public.create_inventory_item_typed(text,text,text,text,uuid,boolean)
from public, anon;

grant execute on function
  public.create_inventory_item_typed(text,text,text,text,uuid,boolean)
to authenticated;
```

This SQL is evidence only in EP-01. It is not applied to the live database by
this document.

## Acceptance gates

EP-01 is complete only when:

- the Purchase Request history contract is reflected in current documentation
  and no frontend/server code depends on absent conversion/completion columns;
- the project anomaly has a user-visible, audited disposition path;
- EP-02 owns the general-overhead versus project-expense decision;
- the inventory creation RPC ACL is fixed by a versioned, reviewed migration
  with a source-contract test;
- the four anonymous asset-link RPCs pass token validity, expiry, replay, and
  information-disclosure UAT;
- RPC-only tables are verified to have no unintended direct grants;
- full tests, build, Quality Gate, Vercel, and relevant RTL regression pass.

## Read-only verification summary

- Project status: `ACTIVE_HEALTHY`
- PostgreSQL: 17
- Purchase Request history orphans: 0
- Purchase Requests without current-state history: 0
- Non-exempt execution without approval: 1
- Unlinked expenses: 1
- Unposted expenses: 1 (the same expense)
- Production data mutations performed: 0
- Production migrations applied: 0
