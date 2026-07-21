# Work Schedule Review Acceptance

## Required workflow

- Open every draft schedule before approval.
- Show scope, effective dates, timezone, weekly hours, breaks, and non-working days.
- Compare the draft with the currently active schedule.
- Allow approval or rejection with a mandatory reason.
- Allow safe cancellation of an active schedule with an effective date and reason.
- Preserve version history and payroll calendar impact.
- Never delete an active or historically referenced schedule.

## Safety

- Additive migration only.
- Existing schedules and payroll records remain unchanged unless an explicit reviewed action is performed.
- All approval, rejection, cancellation, and replacement actions are permission checked and audited.
- Smoke tests must run inside a transaction and roll back.
