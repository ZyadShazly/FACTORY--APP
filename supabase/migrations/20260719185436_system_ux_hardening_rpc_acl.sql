revoke all on function public.renew_asset_confirmation_link(uuid,text) from public, anon;
grant execute on function public.renew_asset_confirmation_link(uuid,text) to authenticated;
revoke all on function public.deactivate_employee(uuid,text) from public, anon;
grant execute on function public.deactivate_employee(uuid,text) to authenticated;
revoke all on function public.save_system_settings(jsonb) from public, anon;
grant execute on function public.save_system_settings(jsonb) to authenticated;
revoke all on function public.get_system_settings() from public, anon;
grant execute on function public.get_system_settings() to authenticated;
