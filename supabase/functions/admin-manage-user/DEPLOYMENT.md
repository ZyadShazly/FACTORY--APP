# admin-manage-user deployment

`admin-manage-user` validates the caller JWT inside the function with `caller.auth.getUser(token)` before any privileged operation.

The project uses asymmetric (`ES256`) Auth access tokens. Deploy this function with gateway JWT verification disabled so the gateway does not reject the asymmetric token before the function's own verification runs:

```bash
supabase functions deploy admin-manage-user --no-verify-jwt
```

Do not remove the in-function `Authorization` header check, `auth.getUser(token)` verification, active-profile lookup, or Owner/Manager role checks.

Production was moved to this mode during post-merge UAT remediation on 2026-08-12. This setting is required for the current managed-account flow.
