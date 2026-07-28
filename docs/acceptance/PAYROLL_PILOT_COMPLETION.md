# Phase 7 — Payroll Pilot Completion

## Scope and safety

This phase completes the employee-level payroll review and approval path. It does not change the existing generated payroll formula, add an attendance ledger, merge a PR, or apply a migration to production.

Migration: `202607280004_payroll_pilot_completion.sql` (additive, repository only).

## Review contract

- A new payroll record remains a draft until a reviewer opens it and completes the employee review.
- Scheduled work days and minutes are derived from the already-approved, versioned work calendar through `resolve_work_calendar`.
- Attendance and absence are review evidence entered by an authorized reviewer. They are never inferred or fabricated.
- The reviewer must record a human-readable source reference for attendance and absence.
- Attendance plus absence must equal the scheduled work days.
- Overtime, deductions, advances, and bonuses keep their existing calculation behavior. Any non-zero deduction, advance, or bonus requires its existing reason field.
- Gross and net values keep the existing generated database formula. This phase adds no new payroll formula.
- Approval is blocked in both the UI and the database when required evidence is missing or the calendar is stale.
- Approval, rejection, and payment use protected RPCs. Direct status transitions are rejected.
- The existing payroll audit trigger continues to capture every update. The detail drawer also exposes the review, attendance, approval, rejection, and payment timestamps/actors.

## Number sources shown in the drawer

| Values | Source |
| --- | --- |
| Base salary and allowances | Employee snapshot stored on the monthly payroll row |
| Scheduled days/minutes | Approved versioned work calendar |
| Attendance and absence | Reviewer-supplied source reference |
| Overtime, deductions, advances, bonuses | Authorized review input; reasons required where applicable |
| Gross and net salary | Existing generated payroll formula |

## Permission and compatibility notes

- Existing payroll visibility and role permissions are preserved.
- `get_payroll_review_snapshot`, `update_payroll_review`, `review_payroll`, and `mark_payroll_paid` require authenticated, permission-checked access.
- Security-definer functions added or replaced by this migration use an empty search path and schema-qualified references.
- Existing approved and paid historical rows are not rewritten. The stronger evidence rules apply when a row transitions through the new approval workflow.
- Covering indexes are added for payroll foreign-key columns without duplicating the existing employee/month unique index or Actual Cost index.

## Pilot acceptance / Bug M

1. Create a monthly payroll draft for an active employee.
2. Open the employee detail drawer.
3. Confirm working days, attendance, absence, overtime, advances, deductions and reason, bonuses, gross salary, and net salary are visible with sources.
4. Confirm approval is disabled and the drawer explains missing evidence.
5. Edit the review, enter attendance, absence, and a real source reference, then save.
6. Confirm scheduled days/minutes came from the approved work calendar.
7. Confirm a mismatched attendance/absence total is rejected with friendly Arabic guidance.
8. Approve with `payroll_approve`; confirm a user without the permission cannot approve.
9. Mark an approved row paid with `payroll_mark_paid`; confirm direct table status updates are guarded.
10. Confirm active drafts/rejections appear first and approved/paid cycles remain in the collapsed archive.

Desktop and mobile RTL acceptance must verify the drawer, blocker message, form inputs, fixed primary action, active list, and collapsed archive without horizontal overflow.
