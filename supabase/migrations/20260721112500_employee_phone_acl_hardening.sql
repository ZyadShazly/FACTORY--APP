-- Internal helper only: generated columns and triggers do not require API execution rights.
revoke all on function public.normalize_employee_phone(text) from public;
revoke all on function public.normalize_employee_phone(text) from anon;
revoke all on function public.normalize_employee_phone(text) from authenticated;
