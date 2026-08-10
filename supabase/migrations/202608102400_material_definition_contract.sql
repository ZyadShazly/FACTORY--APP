-- Close the last direct-write path in the raw-material catalog.
begin;

alter table public.materials add column if not exists command_id uuid;
create unique index if not exists materials_command_uidx
  on public.materials(command_id) where command_id is not null;

create or replace function public.create_material_definition(
  material_name text,
  material_code text,
  material_unit text,
  command_id uuid default gen_random_uuid()
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare saved public.materials%rowtype;
begin
  if not private.inventory_manage_allowed() then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if nullif(btrim(material_name),'') is null then raise exception using errcode='22023',message='Material name is required'; end if;
  if nullif(btrim(material_code),'') is null then raise exception using errcode='22023',message='Material code is required'; end if;
  if nullif(btrim(material_unit),'') is null then raise exception using errcode='22023',message='Material unit is required'; end if;
  if command_id is null then raise exception using errcode='22023',message='Command id is required'; end if;
  select * into saved from public.materials where materials.command_id=create_material_definition.command_id;
  if found then return to_jsonb(saved); end if;

  insert into public.materials(name,material_code,unit,unit_cost,initial_stock,active,command_id)
  values(btrim(material_name),btrim(material_code),btrim(material_unit),0,0,true,command_id)
  returning * into saved;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('materials',saved.id::text,'material_created',auth.uid(),to_jsonb(saved),jsonb_build_object('source','material_catalog'));
  return to_jsonb(saved);
end $$;

revoke all on function public.create_material_definition(text,text,text,uuid) from public,anon,authenticated;
grant execute on function public.create_material_definition(text,text,text,uuid) to authenticated;

drop policy if exists materials_insert_all on public.materials;
drop policy if exists materials_insert_permission on public.materials;
revoke insert,update,delete on table public.materials from anon,authenticated;

commit;
