-- UAT-010: prevent new material duplicates after identity normalization.
-- Additive and backward compatible: existing legacy duplicates and missing codes are reported, not rewritten.

begin;

alter table public.materials
  add column if not exists material_code text;

create or replace function public.normalize_material_identity(value text)
returns text
language sql
immutable
strict
set search_path = public, pg_temp
as $$
  select lower(regexp_replace(btrim(value), '\s+', ' ', 'g'))
$$;

comment on function public.normalize_material_identity(text) is
  'Canonical material identity used to detect case/whitespace duplicates such as mdf and MDF.';

create or replace function public.normalize_material_code(value text)
returns text
language sql
immutable
strict
set search_path = public, pg_temp
as $$
  select upper(regexp_replace(btrim(value), '\s+', '-', 'g'))
$$;

comment on function public.normalize_material_code(text) is
  'Canonical material code used for case-insensitive uniqueness and stable operational references.';

create or replace function public.guard_material_identity()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  normalized_name text := public.normalize_material_identity(new.name);
  normalized_code text;
begin
  if normalized_name is null or normalized_name = '' then
    raise exception using
      errcode = '23514',
      message = 'Material name is required after normalization';
  end if;

  if exists (
    select 1
    from public.materials existing
    where existing.id is distinct from new.id
      and public.normalize_material_identity(existing.name) = normalized_name
  ) then
    raise exception using
      errcode = '23505',
      message = 'A material with the same normalized name already exists',
      detail = format('normalized_name=%s', normalized_name),
      hint = 'Use the existing material or choose a genuinely different material identity.';
  end if;

  if tg_op = 'INSERT' and coalesce(btrim(new.material_code), '') = '' then
    raise exception using
      errcode = '23514',
      message = 'Material code is required for new materials';
  end if;

  if new.material_code is not null then
    normalized_code := public.normalize_material_code(new.material_code);
    if normalized_code = '' then
      raise exception using errcode = '23514', message = 'Material code cannot be empty';
    end if;
    if exists (
      select 1
      from public.materials existing
      where existing.id is distinct from new.id
        and existing.material_code is not null
        and public.normalize_material_code(existing.material_code) = normalized_code
    ) then
      raise exception using
        errcode = '23505',
        message = 'A material with the same normalized code already exists',
        detail = format('normalized_code=%s', normalized_code),
        hint = 'Use a unique material code.';
    end if;
    new.material_code := normalized_code;
  end if;

  new.name := regexp_replace(btrim(new.name), '\s+', ' ', 'g');
  return new;
end $$;

comment on function public.guard_material_identity() is
  'Blocks duplicate material names/codes while preserving legacy rows that predate the guarded identity contract.';

drop trigger if exists materials_identity_guard on public.materials;
create trigger materials_identity_guard
before insert or update of name, material_code on public.materials
for each row execute function public.guard_material_identity();

create unique index if not exists materials_material_code_normalized_uidx
  on public.materials (public.normalize_material_code(material_code))
  where material_code is not null;

create or replace view public.material_duplicate_candidates as
select
  public.normalize_material_identity(name) as normalized_name,
  count(*)::integer as duplicate_count,
  array_agg(id order by created_at nulls last, id) as material_ids,
  array_agg(name order by created_at nulls last, id) as material_names
from public.materials
group by public.normalize_material_identity(name)
having count(*) > 1;

create or replace view public.material_identity_reconciliation as
select
  id,
  name,
  material_code,
  case
    when material_code is null or btrim(material_code) = '' then 'missing_code'
    else 'ok'
  end as identity_status
from public.materials
where material_code is null or btrim(material_code) = '';

comment on view public.material_duplicate_candidates is
  'Read-only reconciliation view for legacy material names that already collide after normalization.';
comment on view public.material_identity_reconciliation is
  'Read-only list of legacy materials that still require an owner-reviewed unique material code.';

revoke all on public.material_duplicate_candidates, public.material_identity_reconciliation from public, anon;
grant select on public.material_duplicate_candidates, public.material_identity_reconciliation to authenticated;

commit;
