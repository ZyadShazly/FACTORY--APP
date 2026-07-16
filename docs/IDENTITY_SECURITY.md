# Identity & Security — Owner Bootstrap and Verification

## Role hierarchy

| Role | Display name | Authority |
| --- | --- | --- |
| `owner` | مالك النظام | Full system access calculated from role; may administer other owners and managers subject to last-owner protection. |
| `manager` | مدير النظام | Full operational access; may administer accountant and production accounts only through the protected RPC. |
| `accountant` | محاسب | Existing defaults plus approved custom permissions. |
| `production` | موظف إنتاج | Customizable safe operational pages only; financial and administrative isolation remains enforced by RLS. |

Protected profile fields (`role`, `permissions`, and `status`) cannot be changed by direct REST updates. The application calls `admin_update_profile`, which validates the hierarchy and writes allowed and denied attempts to `audit_log`.

## Migration order

Apply migrations in filename order. For this phase, the new final migration is:

```text
202607160001_enforce_owner_manager_hierarchy.sql
```

It must run after `202607150003_owner_identity_security.sql`. It does not weaken self-signup restrictions: new users may still create only `accountant` or `production` profiles with empty permissions and active status.

## Promote an existing account to Owner

1. Apply all migrations through `202607160001_enforce_owner_manager_hierarchy.sql`.
2. Open `supabase/scripts/promote_existing_user_to_owner.sql` locally.
3. Copy it into Supabase SQL Editor without saving personal values to Git.
4. Set exactly one variable inside the `DO` block:
   - `target_email` to the existing profile email; or
   - `target_user_id` to the existing Auth/profile UUID.
5. Run the entire transaction once.
6. Confirm the notice reports the expected UUID and verify the profile role is `owner`.
7. Sign in normally with the same email and password. The script does not create or modify Auth credentials.
8. Remove personal values from any local copy/history under your control.

Never put an actual email, UUID, password, service-role key, or other secret in the repository. Do not expose `service_role` through a `VITE_` variable or frontend code.

## Security verification

- A manager cannot modify, suspend, demote, or delete an owner.
- A manager cannot modify, suspend, demote, or delete another manager.
- A manager can administer accountant and production accounts only and cannot promote either account to manager or owner.
- An owner may administer managers through `admin_update_profile` and `admin_delete_profile`.
- No user can change their own role, permissions, or status.
- A manager cannot promote any account to owner.
- The last owner cannot be deleted, suspended, or demoted.
- The last active manager cannot be removed when no active owner exists.
- Direct REST changes to protected profile fields are rejected.
- Owner and manager permissions are calculated from role and ignore stored checkboxes.
- Production financial and administrative RLS restrictions remain active.
- Audit Log is append-only for all application users.
- Profile Realtime updates recalculate navigation immediately; suspension ends the affected session safely.

## Two-session acceptance before merge

1. Apply the migration to a non-production Supabase project and bootstrap one existing test account as Owner.
2. Open the Owner and Manager accounts in separate browser profiles.
3. Confirm the Manager sees Owner and other Manager fields disabled, with the message `لا يمكن لمدير النظام إدارة مدير نظام آخر.`
4. From the Owner session, change another account between `accountant`, `production`, and `manager`; confirm the affected session updates its navigation without refresh.
5. Remove the affected user's current page permission and confirm the app moves to the first allowed page.
6. Remove every page and confirm the explicit no-access state appears instead of a blank or unauthorized page.
7. Suspend the affected account and confirm its session ends safely with the suspension message.
8. Attempt direct REST updates for `role`, `permissions`, and `status`; each request must fail.
9. Call `admin_update_profile` as a Manager targeting the Owner and as a user targeting itself; confirm both return `ok: false` and appear in Audit Log.
10. Verify the final Owner and final Manager protections with isolated test accounts before production rollout.
