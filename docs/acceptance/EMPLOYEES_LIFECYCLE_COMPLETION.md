# Employee Lifecycle Completion — Phase 6

## Scope and safety

Phase 6 completes the employee lifecycle on branch
`agent/employees-lifecycle-completion`. It preserves the existing employee
authorization and checked-delete workflow, and adds exact dependency evidence
through the additive migration
`202607280003_employee_lifecycle_completion.sql`.

- لم تُطبّق على Supabase؛ the migration remains repository-only.
- No employee, payroll, asset, project, production, or audit row is rewritten or deleted.
- Direct employee deletion remains blocked.
- Permanent deletion remains available only through
  `delete_employee_if_unused`, after the dependency summary proves that the
  employee has no linked account or transaction.
- The separate `agent/safe-delete-dependency-explorer` branch is not modified
  or duplicated. This phase extends only the established employee-specific
  dependency contract.

## Delivered lifecycle

- Add a new employee with a validated international WhatsApp number.
- Edit the employee master record through the authorized RPC.
- Archive an active employee with a mandatory reason.
- Restore an archived employee with a mandatory reason.
- Keep suspended, resigned, and terminated employees in a collapsed archive.
- Show active employees first.
- Offer permanent deletion only for a truly unused test record.
- Convert foreign-key failures into a friendly Arabic explanation and guide the
  user back to the employee dependency view.
- Keep the linked login account unchanged when the employee lifecycle changes.

## Dependency evidence

The employee drawer shows the count and exact record label/reference for every
implemented employee dependency:

| Business dependency | Authoritative source | Evidence shown |
| --- | --- | --- |
| Payroll | `payroll.employee_id` | Payroll row ID, month, state, and advance amount |
| Advances | `payroll.advances` | Shown on the exact payroll row that contains the advance |
| Asset custody | `asset_assignments.receiver_employee_id` | Assignment code, state, and project ID |
| Attendance configuration | `work_schedules.employee_id` and `holiday_scopes.employee_id` | Schedule/holiday name, dates, and state |
| Project assignments | `project_members.employee_id` and `project_milestones.responsible_employee_id` | Project code/name, role or milestone, and state |
| Production assignment | `production_order_operations.assigned_employee_id` | Operation, state, and production order ID |
| Login identity | `profiles.employee_id` | Account ID, role, and state |

لا توجد جداول مستقلة للحضور أو السلف في الـ schema الحالي.

- الحضور: يمثله حاليًا `work_schedules` و`holiday_scopes` المرتبطان بالموظف.
- السلف: محفوظة في `payroll.advances` وتظهر داخل سجل مسير الراتب الفعلي.

العمالة الخارجية: **غير منطبق** على حذف الموظف حاليًا.
`daily_labor` stores an external worker snapshot and has no foreign key to
`employees`.

## Data and performance protection

- Existing covering indexes are reused for payroll, profiles, asset assignments,
  project members, project milestones, and production operations.
- Two missing partial indexes are added for
  `work_schedules(employee_id)` and `holiday_scopes(employee_id)`.
- Index names are unique and use `CREATE INDEX IF NOT EXISTS`.
- The replacement dependency function keeps the existing role authorization,
  uses a fixed empty search path, and keeps its established authenticated-only
  execute grant.
- The checked-delete RPC still recomputes the summary inside the delete
  transaction, so a dependency created after opening the drawer blocks deletion
  safely and returns the refreshed evidence.

## Bug H traceability

| Requirement | Evidence |
| --- | --- |
| Add and edit | Existing create path plus `update_employee_record`; retained in the workspace |
| Archive and restore | `set_employee_status` with mandatory reason; explicit Arabic actions |
| Safe delete only when unused | `delete_employee_if_unused` and direct-delete trigger remain authoritative |
| Exact asset, payroll, attendance, advance, and project dependencies | `dependency_records` response and `DependencySummary` UI |
| Preserve employee history | Archive is the normal path; permanent delete is hidden whenever any dependency exists |
| No raw FK errors | `23503`/foreign-key errors map to a friendly Arabic recovery message |
| Active first, archive collapsed | Separate active panel followed by a closed `ArchiveSection` |

## UAT scenarios

1. Add an employee, edit the title/department, and confirm the change refreshes.
2. Archive an active employee with a reason and confirm it leaves the active list
   and appears in the collapsed archive.
3. Restore the employee and confirm it returns to the active list without
   changing a linked login account.
4. Open an employee with payroll, an advance, an asset assignment, attendance
   configuration, and a project assignment; confirm each exact source record is
   listed.
5. Confirm permanent delete is absent for that linked employee.
6. Open a truly unused test employee, request permanent deletion with a reason,
   and confirm the audit-protected RPC succeeds.
7. Create a dependency after opening the unused employee, then request deletion;
   confirm the RPC rejects it and refreshes the dependency evidence.
8. Verify desktop and mobile RTL layouts: the primary add action remains visible,
   the active list appears first, and archive/history remains collapsed.

## Validation

- Focused employee lifecycle tests: 16 passed, 0 failed.
- Full regression suite: 349 passed, 0 failed, 2 intentionally skipped.
- Production build: passed with 2,399 modules transformed.
- Desktop RTL: 4 KPIs, visible primary action, active employees first, archive
  closed by default, and no page overflow.
- Mobile RTL (375 × 812 target): no page/main overflow, contained table
  scrolling, visible primary action, and two archived rows with restore actions.
- `git diff --check`: passed.
- Remote Draft PR gates: recorded after the Draft PR is opened.
- No production migration is applied by this phase.
