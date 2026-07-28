# NextEP Design System Foundation

## Scope

Phase 1 adds reusable presentation primitives without changing module data contracts, permissions, workflow rules, or mutations.

| Component | Purpose |
| --- | --- |
| `PageHeader` | One clear screen title, description, primary action, and optional secondary actions |
| `KpiGrid` / `KpiCard` | Consistent KPI presentation with a documented maximum of five cards |
| `PrimaryActionBar` | Persistent primary action with secondary actions kept visually subordinate |
| `SearchFilterBar` | Consistent search, filters, and filter actions |
| `StatusBadge` | Text-labelled status that does not rely on color alone |
| `EmptyState` | Clear empty state with explanation and optional next action |
| `DetailsDrawer` | On-demand record details with Escape and backdrop close behavior |
| `ArchiveSection` | Collapsed-by-default completed, cancelled, rejected, or historical content |
| `DependencySummary` | Presentation slot for dependency counts and direct record actions |
| `HelpText` | Concise contextual explanation for unfamiliar terms or blocked actions |
| `ResponsiveTable` | Contained horizontal table overflow on narrow screens |
| `ResponsiveCardGrid` | Responsive record-card layout |

## Compatibility

- Existing `src/operational/ui.jsx` exports and behavior are unchanged.
- New components are re-exported from the operational UI boundary for gradual adoption.
- No existing module has been rewritten to use the new primitives in this foundation phase.
- CSS uses the existing NextEP design tokens and logical RTL properties.

## Safety

- Supabase access: none
- RPCs: none
- Business rules: none
- Permission logic: none
- Schema/migrations: none
- Production data: untouched

## Adoption rules

1. Adopt components during the relevant module phase, not through a broad monolith rewrite.
2. Keep one screen focused on one job.
3. Keep KPI groups at five cards or fewer.
4. Supply visible status labels; tone is supplemental only.
5. Put completed and historical records in `ArchiveSection` by default.
6. Use `DetailsDrawer` for decision detail that should not crowd the primary list.
7. Keep a single obvious primary action in `PageHeader` or `PrimaryActionBar`.

## Validation

| Check | Result |
| --- | --- |
| Focused component contracts | Passed — 7/7 |
| Full `npm test` | Passed — 298 passed, 0 failed, 2 skipped |
| `npm run build` | Passed — 2,398 modules transformed |
| `git diff --check` | Passed |
| Desktop application regression QA | Passed — 1,440 × 900; no horizontal overflow |
| Mobile application regression QA | Passed — 375 × 812; no horizontal overflow |
| RTL QA | Passed — Arabic language and RTL direction retained |
| Browser console | Passed — no warnings or errors on a clean local server |
| Remote quality gate | Passed on Draft PR #85 |
| Vercel | Passed on Draft PR #85 |

Status and contextual-help foreground/background pairs are covered by an automated WCAG AA contrast test at the normal-text threshold.
