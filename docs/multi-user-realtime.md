# Multi-user Realtime verification

## Prerequisite

Apply the Supabase migrations in filename order through
`202607140003_enable_multi_user_realtime.sql`. The last migration adds the
operational tables to `supabase_realtime`, introduces profile account status,
and blocks suspended profiles from operational tables.

The application owns both Realtime channels in one lifecycle effect:

- `factory-data-<user-id>` listens to every table represented in application state.
- `factory-profile-<user-id>` listens only to the signed-in user's profile row.

Both channels are removed on logout/unmount. Channel errors and timeouts use
bounded exponential reconnect delays, and the browser `online` event triggers an
immediate reconnect. Development builds show the connection state in the sidebar;
all builds log channel state and received table events in the console.

## Two-browser acceptance scenario

1. Open Browser A and sign in as a manager.
2. Open Browser B (or a private browser profile) and sign in as an employee.
3. Confirm both consoles report `CONNECTED` for the data and profile channels.
4. In Browser A, create a project. Browser B must show it without refresh.
5. In Browser A, grant Browser B access to a page. Its navigation and action
   guards must update without logout or refresh.
6. Keep that page open in Browser B, then remove the page permission in Browser A.
   Browser B must move to the first allowed page immediately.
7. Set Browser B's account status to `suspended`. Browser B must show the account
   suspension message and end its local session immediately.
8. Restore the account to `active`, sign in again, and confirm access reflects the
   latest role and permissions.
9. Temporarily take Browser B offline, make a change in Browser A, then restore
   connectivity. Browser B must reconnect and receive/refetch subsequent changes.

## Database verification

Use this query in the Supabase SQL editor to confirm publication membership:

```sql
select tablename
from pg_publication_tables
where pubname = 'supabase_realtime'
  and schemaname = 'public'
order by tablename;
```

The purchases screen uses `material_purchases`. If a separate legacy `purchases`
table exists, the migration also adds it to the publication without changing the
application's source of truth.
