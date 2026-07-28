# Pilot Baseline Stabilization

## Outcome

Phase 0 restores a trustworthy cross-platform baseline without changing application business behavior.

## Root cause

`scripts/apply-operational-bug-closure.mjs` detected an already-applied multiline replacement using an LF-only string. A Windows CRLF checkout therefore looked unpatched, after which the script searched for obsolete source and failed with `Missing expected source for payroll review module route`.

The existing test correctly used an isolated temporary fixture, so it did not mutate the real checkout, but it inherited the host checkout's line endings and exposed the platform bug.

## Changes

- Normalize search and replacement text to the target file's existing line ending.
- Preserve the target file's LF or CRLF convention.
- Verify two consecutive no-op patch runs against explicit LF and CRLF fixtures.
- Verify fixture content is unchanged after each rerun.
- Make the clean-tree gate include untracked files.
- Test that an unexpected test artifact fails the clean-tree gate.
- Upgrade GitHub Actions from Node 20-based action majors to the current Node 24-based v7 actions.

## Validation

| Check | Result |
| --- | --- |
| Focused baseline tests | Passed — 9/9 |
| Full `npm test` | Passed — 291 passed, 0 failed, 2 skipped |
| `npm run build` | Passed — 2,396 modules transformed |
| Test working-tree comparison | Passed — no change |
| Build working-tree comparison | Passed — no change |
| `git diff --check` | Pending final commit check |
| Desktop QA | Passed — 1,440 × 900, no horizontal overflow |
| Mobile QA | Passed — 375 × 812, no horizontal overflow |
| RTL QA | Passed — Arabic `lang`, RTL `dir`, readable controls and content |
| Browser console | Passed — no warnings or errors in demo smoke test |
| Remote quality gate | Pending Draft PR |
| Vercel | Pending Draft PR |

The build continues to emit the existing large-monolith chunk advisory. Phase 0 does not change bundle boundaries because broad `AppMonolith` refactoring is explicitly out of scope.

## Product and data impact

- Business rules: unchanged
- UI behavior: unchanged
- Database schema/RLS/RPCs: unchanged
- Migrations: none
- Production Supabase: untouched
- User data: untouched
