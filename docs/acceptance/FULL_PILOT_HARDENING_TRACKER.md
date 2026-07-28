# Full Pilot Hardening Tracker

Last updated: 2026-07-28

This tracker is the evidence index for the NextEP factory pilot mission. Every implementation phase must remain isolated in its own Draft PR. No PR is merged and no production migration is applied by this mission.

| Phase | Branch | PR | Status | Tests | Build | Quality gate | Vercel | Migration status | Risks | UAT scenarios | Blockers |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 — Baseline stabilization | `agent/pilot-baseline-stabilization` | [#84](https://github.com/ZyadShazly/FACTORY--APP/pull/84) | Draft, open, implementation complete | Focused 9/9; full 291 passed, 0 failed, 2 skipped | Passed, 2,396 modules | Passed; no annotations | Passed | None | Existing monolith chunk advisory only | LF/CRLF idempotency; clean test/build tree; desktop/mobile/RTL smoke passed | None |
| 1 — Design system foundation | `agent/nextep-design-system-foundation` | [Draft PR #85](https://github.com/ZyadShazly/FACTORY--APP/pull/85) | Open Draft; implementation and validation complete; stacked on Phase 0 | Focused 7/7; full 298 passed, 0 failed, 2 skipped | Passed, 2,398 modules | Passed | Passed | None | Adoption must remain gradual to avoid shared-file conflicts | Responsive RTL contracts; desktop/mobile smoke passed | None |
| 2 — Procurement completion | `agent/procurement-pilot-completion` | [Draft PR #86](https://github.com/ZyadShazly/FACTORY--APP/pull/86) | Open Draft; local implementation and automated validation complete; stacked on Phase 1 | Focused 30/30; full 309 passed, 0 failed, 2 skipped | Passed, 2,398 modules | Pending | Pending | Additive migration created; not applied | Reused PR #80 commits; PR #80 remains open and must not be merged alongside this migration without reconciliation | PR → approval → draft PO → preview → approval → print/send → receipt → invoice; live visual QA pending | None |
| 3 — Inventory pilot hardening | `agent/inventory-pilot-hardening` | Pending | Not started | Pending | Pending | Pending | Pending | Review required | Recently merged Inventory UX must remain backward compatible | Full inventory UAT and Bug A/B | None known |
| 4 — Production completion | `agent/production-pilot-completion` | Pending | Not started | Pending | Pending | Pending | Pending | Review required | Open PR #34 and recently merged partial issue work may overlap | Partial batches through completion/cancellation | PR #34 scope review |
| 5 — Project completion | `agent/project-pilot-completion` | Pending | Not started | Pending | Pending | Pending | Pending | Review required | Downstream state blocking needs compatibility review | Budget approval through closure | Product-state rules may require evidence |
| 6 — Employee lifecycle | `agent/employees-lifecycle-completion` | Pending | Not started | Pending | Pending | Pending | Pending | Review required | Must not duplicate Safe Delete work | Add/edit/archive/restore/dependencies | Safe Delete branch owned by another agent |
| 7 — Payroll completion | `agent/payroll-pilot-completion` | Pending | Not started | Pending | Pending | Pending | Pending | Review required | Formula changes prohibited without proof | Review sources and approve cycle | None known |
| 8 — External labor | `agent/external-labor-pilot-completion` | Pending | Not started | Pending | Pending | Pending | Pending | Review required | Payment/audit contract review required | Review then approve/pay | None known |
| 9 — Assets completion | `agent/assets-pilot-completion` | Pending | Not started | Pending | Pending | Pending | Pending | Review required | Existing asset branches/PRs require reconciliation | Assign, confirm, return, close | Existing work review |
| 10 — Expenses hardening | `agent/expenses-financial-hardening` | Pending | Not started | Pending | Pending | Pending | Pending | Review required; never apply to production | RLS and reversal changes are high-risk | Create/edit/reverse with permissions | None known |
| 11 — Commercial master data | `agent/commercial-master-data-hardening` | Pending | Not started | Pending | Pending | Pending | Pending | Review required | Must preserve linked financial history | Products/suppliers/clients/sales lifecycle | Safe Delete integration boundary |
| 12 — Reports and exports | `agent/reports-pilot-polish` | Pending | Not started | Pending | Pending | Pending | Pending | None planned | Existing reporting engine must be improved, not replaced | Excel/PDF manager review | None known |
| 13 — Navigation and help | `agent/global-navigation-help` | Pending | Not started | Pending | Pending | Pending | Pending | None planned | Shared shell conflicts must be minimized | Find related records and blocked-action help | None known |
| 14 — Error/dependency integration | `agent/global-error-experience-integration` | Pending | Not started | Pending | Pending | Pending | Pending | Review required | Must integrate merged Safe Delete work, never duplicate | Friendly mapping and dependency actions | Wait for Safe Delete merge state |
| 15 — E2E regression | `agent/full-pilot-e2e-regression` | Pending | Not started | Pending | Pending | Pending | Pending | Review only | No features allowed; evidence depends on accessible UAT environment | 30-step pilot flow and Bugs A–R traceability | Live UAT credentials/environment may be required |

## Coordination register

- PR #80 (`agent/fix-procurement-print-templates`) remains an open Draft. Phase 2 reused its two commits and completed them on the stacked phase branch; the two PRs must be reconciled before any future merge to avoid applying migration `202607260002` twice.
- PR #34 (`feat/production-execution-quality`) is an open Draft PR and must be reviewed before Phase 4.
- `agent/safe-delete-dependency-explorer` exists and is owned by another agent. Phases 6, 11, and 14 must not overwrite or duplicate that work.
- Inventory UX PR #83 was merged into `main` before this mission began and is the Phase 3 review baseline.

## Mission safety state

- Production Supabase migrations applied by this mission: **none**
- PRs merged by this mission: **none**
- Auto-merge enabled by this mission: **none**
- User data created, deleted, reset, rewritten, or fabricated: **none**
