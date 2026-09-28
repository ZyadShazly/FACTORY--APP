-- Pilot security closeout: internal RPCs are authenticated-only.
-- Public secret-token asset confirmation RPCs remain intentionally anonymous.

revoke all on function public.get_audit_log_visible()
from public, anon;
grant execute on function public.get_audit_log_visible()
to authenticated;

revoke all on function public.owner_override_purchase_request_budget(uuid,text)
from public, anon;
grant execute on function public.owner_override_purchase_request_budget(uuid,text)
to authenticated;

revoke all on function public.owner_recover_asset_assignment_state(uuid,text)
from public, anon;
grant execute on function public.owner_recover_asset_assignment_state(uuid,text)
to authenticated;
