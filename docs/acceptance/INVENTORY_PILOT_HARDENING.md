# Inventory Pilot Hardening

## Scope

Phase 3 reviews the merged Inventory workspace against the factory-pilot workflow and closes the remaining Bug A usability gaps. It does not change inventory accounting, authorization, RLS, RPC behavior, database schema, or migrations.

The existing Bug B opening-inventory implementation remains the canonical workflow:

- draft document before any balance effect;
- item, warehouse, optional location, quantity, unit cost, and total value;
- review before posting;
- one immutable `opening_balance` movement per posted line;
- ledger-derived quantity and value;
- duplicate posting protection and audit history;
- clear separation from normal Purchase Receipt.

## Bug A hardening

- The Inventory Items screen includes a collapsed explanation of Raw Material, Inventory Item, Warehouse Balance, Opening Inventory, and Inventory Movement.
- Raw Materials now show the linked inventory item by display name and SKU.
- Users can create an item from a material, open the existing-item linking screen, and return from Inventory to Raw Materials directly.
- The linking selector excludes materials owned by another inventory item while retaining the current item’s material.
- Material creation performs an explicit protected workspace refresh after the existing mutation/refetch completes.
- A receipt blocked by a missing active inventory link now shows a friendly Arabic explanation and a direct action to the Inventory Items linking screen.

## Preserved contracts

- `get_inventory_workspace`
- `create_inventory_item`
- `manage_inventory_item_catalog`
- `create_opening_inventory_document`
- `save_opening_inventory_line`
- `post_opening_inventory_document`
- `confirm_goods_receipt_to_inventory`
- `transfer_inventory`
- `adjust_inventory`
- `create_inventory_count_session`
- `save_inventory_count_line`
- `post_inventory_count_session`

No client-side direct write was added to Inventory, Opening Inventory, Procurement Receipt, or the movement ledger. Existing Raw Material creation remains unchanged and is immediately followed by the protected workspace refresh.

## Validation

| Check | Result |
| --- | --- |
| Inventory-focused tests | Passed — 43/43 |
| Production build | Passed — 2,398 modules |
| `git diff --check` | Passed |
| Database/migration scope | Passed — no migration or schema file changed |
| Protected RPC regression | Passed |
| Full test suite | Passed — 318 total, 316 passed, 0 failed, 2 intentional environment-gated skips |
| Desktop/mobile/RTL | Passed — desktop 1,440×900 and mobile 375×812, RTL, no global horizontal overflow |
| Quality Gate / Vercel | Passed on Draft PR #87 |

The existing large AppMonolith chunk warning is unchanged and outside this narrow phase.

## Visual QA

- Desktop: document and body remained exactly 1,440 px wide; four KPIs, five workspace tabs, one sticky primary-action bar, and the collapsed concept guide were visible.
- Mobile: at 375×812 the document, body, and Inventory workspace stayed within the 360 px content viewport after scrollbar allocation.
- The segmented tabs and 860 px data table retain intentional internal horizontal scrolling; neither expands the page.
- Opening Inventory remained a dedicated screen, posted history stayed collapsed, and no global overflow appeared.
- Raw Materials showed `linked item name — SKU`, plus direct create, link-existing, and open-linked-item actions without overflow.
- A clean browser tab produced no warning or error logs.

Visual QA used an in-memory read-only fixture and temporary source hook. Both were removed immediately afterward; no Supabase rows, users, `.env` files, or repository artifacts were created.

## Critical UAT traceability

| Scenario | Evidence |
| --- | --- |
| Create an inventory item manually | Existing protected create form and `create_inventory_item` regression |
| Create from raw material | Direct material action plus refreshed protected workspace |
| Link / unlink safely | Filtered selector and existing audited `manage_inventory_item_catalog` |
| Activate / deactivate | Existing capability gate, stock guard, and audit |
| Opening quantity and cost | Dedicated draft line workflow |
| Review and post opening inventory | Immutable ledger posting and duplicate guard |
| Verify balances and value | Workspace totals derive from ledger balances |
| Receive procurement items | Protected atomic receipt; missing link now routes to Inventory |
| Issue production materials | Existing protected Production route |
| Transfer / adjustment / count | Existing protected RPC workflows |
| Movement audit | Movement-only History section and immutable ledger |
