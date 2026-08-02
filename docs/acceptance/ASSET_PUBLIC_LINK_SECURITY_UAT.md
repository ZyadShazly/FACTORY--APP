# Asset Public-Link Security UAT

> **Package:** EP-01
>
> **Snapshot date:** 2026-08-02
>
> **Baseline:** `e000f8fc52eca730235bbb9ddc2a379fec79b2e6`
>
> **Method:** repository contract review plus read-only live SQL inspection

## Decision

The four anonymous Asset confirmation RPCs are intentional public-link
boundaries. Their anonymous grants may remain because the recipient must be able
to confirm through a WhatsApp link without a system account.

They are not generic anonymous mutation endpoints. The link secret is the
authorization credential, and the internal mutation functions have no
`PUBLIC`, `anon`, or `authenticated` execute privilege.

## Verified controls

| Control | Issue confirmation | Return confirmation |
| --- | --- | --- |
| Secret generation | 24 random bytes, hex encoded | 24 random bytes, hex encoded |
| Stored credential | SHA-256 hash only | SHA-256 hash only |
| Plaintext secret in table | No | No |
| Expiration | Configured timestamp and enforced before disclosure/mutation | Configured timestamp and enforced before disclosure/mutation |
| Single use | `confirmation_used_at` plus token hash cleared | `confirmation_used_at` plus token hash cleared |
| Replacement | Renewal creates a new secret and resets attempts/lock | Renewal creates a new secret and resets attempts/lock |
| Invalid attempts | Counted; locked for 15 minutes after five failures | Counted; locked for 15 minutes after five failures |
| Personal data in preview | Receiver name and phone are masked | Receiver name and phone are masked |
| Registered employee path | Requires authenticated matching profile | Requires authenticated matching profile |
| Bearer-link path | Allowed only when no receiver profile is linked | Allowed only when no receiver profile is linked |
| Row concurrency | Target row is locked before validation and mutation | Event, assignment, and item rows are locked |
| Replay resistance | Confirmed state and cleared hash prevent second mutation | Confirmed state and cleared hash prevent second mutation |
| Internal apply RPC ACL | Not executable by `PUBLIC`, `anon`, or `authenticated` | Not executable by `PUBLIC`, `anon`, or `authenticated` |

## Live evidence

Read-only inspection returned:

- assignments: 5 total;
- assignment confirmations used: 3;
- assignment rows retaining a token hash: 0;
- expired unused assignment links: 2;
- return events: 3 total;
- return confirmations used: 3;
- return rows retaining a token hash: 0;
- pending return links: 0.

The expired unused assignment rows do not retain token hashes. No plaintext token
or secret column exists on either confirmation table.

A negative live UAT used a UUID that does not exist and an invalid secret. All
four public functions returned `{"status":"not_found"}`; no row was inserted,
updated, or deleted.

## Information-disclosure boundary

The preview functions disclose state before validating the secret for terminal
states such as `already_confirmed`, `cancelled`, and `expired`. The target
identifier is a random UUID and valid previews mask receiver identity.

This is accepted for the current pilot because it supports a clear user
experience when an old WhatsApp link is reopened. The response must continue to
exclude unmasked names, phone numbers, internal notes, costs, employee IDs,
profile IDs, and audit metadata.

## Denial-of-service boundary

A party who knows a valid target UUID but not the secret can consume failed
attempts and temporarily lock the link. The 15-minute lock protects against
brute force but can delay a legitimate confirmation.

Pilot controls:

- UUIDs must not appear in public listings, analytics events, or error messages;
- resend/renew must rotate the secret and clear attempts and lock state;
- only authorized Asset staff may renew a link;
- the UI must explain temporary lock and renewal without exposing the target UUID;
- repeated lock events should be reviewed through operational monitoring.

A dedicated server-side IP/device throttle can be added after pilot evidence
shows abuse; it is not justified as a speculative schema change in EP-01.

## Regression scenarios

The following scenarios remain mandatory for Assets UAT:

1. Valid unlinked-employee issue link previews masked data and confirms once.
2. Reopening a confirmed issue link returns `already_confirmed` and creates no
   second movement.
3. Expired and replaced links cannot confirm.
4. Five invalid secrets trigger a temporary lock.
5. Renewing a link invalidates the old secret and resets the lock.
6. A linked employee cannot use bearer confirmation and must authenticate.
7. A valid unlinked-employee return link confirms the exact quantities once.
8. A replayed return link creates no second inventory movement.
9. An inconsistent return balance aborts the transaction.
10. Internal apply functions remain non-executable by all API roles.

## Outcome

No security migration is required for the four intentional anonymous functions.
Their Supabase Advisor warnings are accepted-with-controls, not ignored. Future
changes to these functions must preserve the controls above and rerun the
regression scenarios.
