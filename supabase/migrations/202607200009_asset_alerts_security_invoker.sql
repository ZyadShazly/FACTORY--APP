begin;

-- The alert view must execute with the querying user's permissions and RLS,
-- never with the view owner's elevated privileges.
alter view public.asset_alerts set (security_invoker = true);

commit;
