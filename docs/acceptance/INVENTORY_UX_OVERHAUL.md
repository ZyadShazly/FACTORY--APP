# Inventory UX Overhaul — Quality Gate and Regression Report

## Scope

This change reorganizes the Inventory workspace presentation only. It introduces:

- Four dashboard KPIs: inventory items, inventory value, total quantity, and unlinked materials.
- A persistent primary-action bar for creating an item, opening inventory, receiving, and issuing.
- Five workspace sections: Inventory Items, Opening Inventory, Operations, History, and Settings.
- A focused operations selector for Receive, Issue, Transfer, Adjustment, and Count.
- Movement-only history and collapsed posted/archive information.
- Responsive desktop and mobile layouts.

No database schema, migration, RLS, RPC, authorization, or inventory accounting rule was changed.

## Preserved contracts

The existing Inventory RPC and workflow boundaries remain intact:

- `get_inventory_workspace`
- `create_inventory_item`
- `manage_inventory_item_catalog`
- `delete_inventory_setup_entity`
- `transfer_inventory`
- `adjust_inventory`
- `create_inventory_count_session`
- `save_inventory_count_line`
- `post_inventory_count_session`

Receive continues to use the existing Procurement workflow, and Issue continues to use the existing Production workflow. Inventory management actions remain capability-gated, and inventory value remains hidden when financial visibility is unavailable.

## Quality Gate

| Check | Result |
| --- | --- |
| Inventory-focused regression suite | PASS — 40/40 |
| Production build | PASS — 2,396 modules transformed |
| Full test suite | BASELINE EXCEPTION — 287 passed, 1 failed, 2 skipped |
| Database/migration scope | PASS — no schema or migration files changed |
| Browser structure QA | PASS — desktop and 375 px mobile |
| Page-level horizontal overflow | PASS — none observed |

The single full-suite failure is the pre-existing `operational patch is idempotent` test. The patch script still searches for the obsolete combined payroll import even though latest `main` already uses `PayrollReviewTab`. The relevant `main` source and script are unchanged by this branch; the Inventory changes do not touch that payroll route or patch script.

The production build retains the repository's existing large-chunk advisory for the monolith bundle; it is a warning, not a build failure.

## Browser QA

- Desktop: 4 primary actions, 4 KPIs, and 5 navigation tabs rendered; document width matched viewport width.
- Operations: all 5 operation choices rendered with only the selected workflow shown.
- Mobile (375 × 812): no page-level horizontal overflow; primary actions use a two-column grid.
- Segmented navigation intentionally scrolls horizontally on narrow screens.
- Browser QA used the local demo shell with no live Supabase mutations.

## Regression matrix

| Area | Verification |
| --- | --- |
| Inventory catalog | Required columns and create/link/unlink/activate/deactivate actions are present |
| Opening inventory | Existing draft/post workflow retained; posted history collapsed by default |
| Receive | Routes to the current Procurement receiving workflow |
| Issue | Routes to the current Production issuing workflow |
| Transfer | Existing `transfer_inventory` contract retained |
| Adjustment | Existing `adjust_inventory` contract retained |
| Count | Existing create/save/post count contracts retained |
| History | Displays inventory movements only |
| Settings | Warehouses and locations remain available; archived warehouses are collapsed |
| Permissions | Manage actions and financial value continue to honor existing capabilities |
| Backward compatibility | Existing delete action remains available under the secondary “more” control |
