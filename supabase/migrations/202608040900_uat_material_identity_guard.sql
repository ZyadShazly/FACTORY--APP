-- UAT-010: prevent new material duplicates after name normalization.
-- Additive and backward compatible: existing legacy duplicates are reported, not rewritten.

begin;

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

create or replace function public.guard_material_identity()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  normalized text := public.normalize_material_identity(new.name);
begin
  if normalized is null or normalized = '' then
    raise exception using
      errcode = '23514',
      message = 'Material name is required after normalization';
  end if;

  if exists (
    select 1
    from public.materials existing
    where existing.id is distinct from new.id
      and public.normalize_material_identity(existing.name) = normalized
  ) then
    raise exception using
      errcode = '23505',
      message = 'A material with the same normalized name already exists',
      detail = format('normalized_name=%s', normalized),
      hint = 'Use the existing material or choose a genuinely different material identity.';
  end if;

  new.name := regexp_replace(btrim(new.name), '\s+', ' ', 'g');
  return new;
end $$;

comment on function public.guard_material_identity() is
  'Blocks new or renamed material records that collide after trim, whitespace collapse, and case normalization.';

drop trigger if exists materials_identity_guard on public.materials;
create trigger materials_identity_guard
before insert or update of name on public.materials
for each row execute function public.guard_material_identity();

create or replace view public.material_duplicate_candidates as
select
  public.normalize_material_identity(name) as normalized_name,
  count(*)::integer as duplicate_count,
  array_agg(id order by created_at nulls last, id) as material_ids,
  array_agg(name order by created_at nulls last, id) as material_names
from public.materials
group by public.normalize_material_identity(name)
having count(*) > 1;

comment on view public.material_duplicate_candidates is
  'Read-only reconciliation view for legacy material names that already collide after normalization.';

revoke all on public.material_duplicate_candidates from public, anon;
grant select on public.material_duplicate_candidates to authenticated;

commit;
