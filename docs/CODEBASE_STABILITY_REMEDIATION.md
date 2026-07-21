# Codebase stability remediation

## Confirmed mistakes

1. `predev`, `prebuild`, and `pretest` currently mutate tracked source files. This can hide missing committed code and makes builds depend on side effects.
2. The quality workflow also applies source-normalization scripts before tests, so tests do not always validate the exact committed tree.
3. `.env.example` contained the real Supabase project URL and publishable key instead of placeholders.
4. `App.jsx` is still a large integration file and should be split gradually at module boundaries.
5. Version-named folders (`v22`, `v23`) no longer describe their responsibility and should be renamed only through staged compatibility commits.

## Safe correction order

### Phase 1 — materialize generated source

Run all patch scripts once against the latest `main`, review the resulting diff, and commit the generated application source. Do not remove lifecycle hooks before this commit, because current `main` still depends on those patches for operational workspaces and the latest payroll screen.

### Phase 2 — make commands pure

Remove mutating `predev`, `prebuild`, and `pretest` scripts. Replace them with a verification command that runs `git diff --exit-code` after test/build in CI. Remove source-mutating steps from the quality workflow.

### Phase 3 — current schema source

Keep migrations as immutable history. Refresh the live schema snapshot and generated Supabase types after every merged migration.

### Phase 4 — split App.jsx

Extract, in order: application routing and tab registry, data bootstrap/realtime loading, legacy operational screens, and authentication shell. Each extraction must be behavior-preserving and have a separate PR.

### Phase 5 — rename version folders

Rename `src/v22` to responsibility-based folders such as `src/modules` or module-specific directories, and `src/v23/workCalendar.jsx` to `src/modules/work-calendar/WorkCalendarPage.jsx`. Use temporary re-export files so imports can move gradually without a large destructive rename.

## Non-destructive rule

No database data changes, no force updates, and no mass rename should be combined with functional workflow changes.
