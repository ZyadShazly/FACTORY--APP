# Project Pilot Completion

Date: 2026-07-28

Branch: `agent/project-pilot-completion`

Base: Phase 4 Draft PR branch (`agent/production-pilot-completion`)

Draft PR: [#89](https://github.com/ZyadShazly/FACTORY--APP/pull/89)

## Outcome

Phase 5 makes the Project lifecycle explicit and enforceable:

1. create a project draft;
2. prepare its details and estimated budget;
3. approve a positive estimated budget;
4. approve the project;
5. assign an active project manager;
6. start execution;
7. complete and close the project after resolving open dependencies.

The overview now presents this sequence as one visible seven-step timeline with the exact next action. Readiness blockers show the first affected record and a safe alternative. The older generic lifecycle, execution-stage, and progress controls remain available in the collapsed advanced section.

The projects list shows current work first, keeps four KPI cards, and collapses closed/cancelled projects into a preserved archive.

## State and authorization rules

- `planning -> ready_for_activation` requires valid project/customer/date details and an approved positive budget containing a positive line.
- Existing explicit `legacy_activation_exempt` and already-recorded Owner override fields remain honored; no historical row is rewritten.
- `ready_for_activation -> active` continues to use the existing `project_activation_readiness` contract, including manager readiness.
- Manufacturing, painting, installation, or delivered execution stages cannot be selected before the project is active.
- Manager assignment accepts an active profile only. Replacing a manager requires a reason and records the previous manager, new manager, member record, actor, and reason.
- Completion and closure are blocked by incomplete milestones, active purchase requests/orders, unapproved supplier invoices, nonterminal Production orders, or open asset custody.
- The readiness response names the first blocking record and provides the safe close/cancel/return path.

## Downstream decision

Project-linked Procurement and Production activity is permitted only while the project lifecycle is `active`. This applies to requests, quotes, orders, receipts, invoices, Production orders, material requirements, and operations.

The guard intentionally:

- leaves records with no project link unchanged, preserving non-project workflows;
- permits a state change to `cancelled`, `rejected`, or `reversed`, and permits the final settlement states `paid` and `closed`, so users can safely unwind work and settle existing obligations after a project stops;
- does not delete or rewrite existing downstream records;
- reports project ID, code, name, lifecycle, and attempted action in a structured error mapped to friendly Arabic guidance.

## Migration review

New migration:

`202607280002_project_pilot_completion.sql`

The additive migration:

- adds explicit approval, execution-start, completion, and closure actor/timestamp columns;
- adds one idempotent covering index for each new profile foreign key;
- adds readiness and downstream-state helpers with fixed empty search paths;
- adds protected workflow and manager RPCs while preserving the existing authorization helpers;
- records lifecycle and manager changes in `project_activities`;
- redefines the existing execution-stage RPC only to reject execution stages before lifecycle approval;
- does not create policies or modify legacy RLS objects.

The migration was not applied by this mission.

## Bug traceability

### Bug G — Project lifecycle ambiguity

- The next step is visible rather than hidden in advanced controls.
- Budget validity is checked before project approval.
- Manager assignment is a dedicated action.
- Execution and downstream work are rejected until approval and activation.
- Completion returns exact blocking dependencies and safe alternatives.
- Active projects appear first; closed/cancelled history is collapsed.
- Status and manager changes preserve actors, timestamps, previous/new values, and reasons.

## Validation evidence

- Focused Project contracts: 12 passed, 0 failed.
- Full test script body (`node --test tests/*.test.mjs`): 341 total, 339 passed, 0 failed, 2 intentional skips.
- `npm test` launcher is unavailable in the bundled runtime because `npm` is not installed; the exact package script body was executed successfully with the bundled Node runtime.
- Application build: passed, 2,399 modules transformed.
- `git diff --check`: passed.
- Desktop/RTL visual QA: passed at 1,280×720 with `clientWidth=scrollWidth=1,265`, seven workflow steps, five KPI cards, the exact blocking Production record, and the dedicated manager action.
- Mobile/RTL visual QA: passed in a real 375×812 iframe viewport. Navigation and workflow steps use intentional contained horizontal scrolling; the page content stays inside the mobile frame.
- Remote Quality Gate run 317: passed on the implementation commit.
- Vercel deployment: passed on the implementation commit.

## Regression and safety

- No production or local Supabase migration was applied.
- No user or business data was created, changed, deleted, reset, or fabricated.
- Existing Project RPC authorization and visibility helpers are reused.
- Existing explicit legacy activation exemptions and Owner override records are preserved.
- Realtime tables/subscriptions are unchanged.
- No unrelated RLS policy or legacy module schema was changed.
- Visual QA used an in-memory read-only fixture and temporary host files. They were removed immediately afterward; no Supabase rows, users, environment files, or repository artifacts were created.
- No PR was merged and auto-merge remains disabled.
