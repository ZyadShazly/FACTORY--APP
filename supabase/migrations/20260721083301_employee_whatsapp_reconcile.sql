-- Reconcile the live helper column left by the earlier phone draft.
-- No employee values are rewritten and no business rows are removed.

alter table public.employees
  add column if not exists phone_normalized text
  generated always as (public.normalize_employee_phone(coalesce(phone, ''))) stored;

alter table public.employees
  drop constraint if exists employees_phone_required_for_new_rows;

alter table public.employees
  add constraint employees_phone_required_for_new_rows
  check (
    phone_normalized is not null
    and phone_normalized ~ '^\+[1-9][0-9]{7,14}$'
  ) not valid;

-- Keep legacy invalid rows readable; the trigger protects inserts and phone changes.
drop index if exists public.employees_phone_normalized_unique;
create unique index employees_phone_normalized_unique
  on public.employees(phone_normalized)
  where phone_normalized is not null;

comment on column public.employees.phone_normalized is
  'Normalized international WhatsApp number. Legacy invalid rows remain readable until explicitly corrected.';
