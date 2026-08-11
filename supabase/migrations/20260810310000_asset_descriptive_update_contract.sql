-- Keep asset edits descriptive; quantities, locations and operational states move only through ledger workflows.
begin;

create or replace function public.update_asset_record(target_id uuid,payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  asset_row public.assets%rowtype;
  target_category uuid:=nullif(payload->>'category_id','')::uuid;
begin
  if auth.uid() is null or not public.has_permission('assets_manage') or not public.is_current_profile_active() then
    raise exception using errcode='42501',message='assets_manage permission required';
  end if;
  if nullif(btrim(payload->>'name'),'') is null then raise exception using errcode='22023',message='Asset name is required'; end if;
  if target_category is not null and not exists(select 1 from public.asset_categories where id=target_category) then
    raise exception using errcode='23503',message='Asset category not found';
  end if;

  select * into asset_row from public.assets where id=target_id for update;
  if not found then raise exception using errcode='P0002',message='Asset not found'; end if;

  update public.assets set
    asset_code=coalesce(nullif(btrim(payload->>'asset_code'),''),asset_code),
    name=btrim(payload->>'name'),
    description=coalesce(payload->>'description',description),
    category_id=coalesce(target_category,category_id),
    brand=coalesce(payload->>'brand',brand),
    model=coalesce(payload->>'model',model),
    serial_number=coalesce(nullif(btrim(payload->>'serial_number'),''),serial_number),
    qr_value=coalesce(nullif(btrim(payload->>'qr_value'),''),qr_value),
    barcode_value=coalesce(nullif(btrim(payload->>'barcode_value'),''),barcode_value),
    warehouse=coalesce(payload->>'warehouse',warehouse),
    shelf=coalesce(payload->>'shelf',shelf),
    notes=coalesce(payload->>'notes',notes),
    updated_by=auth.uid(),updated_at=statement_timestamp()
  where id=target_id returning * into asset_row;

  return jsonb_build_object('ok',true,'asset',to_jsonb(asset_row));
end
$$;

revoke all on function public.update_asset_record(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.update_asset_record(uuid,jsonb) to authenticated;

comment on function public.update_asset_record(uuid,jsonb) is
  'Updates descriptive asset fields only. Quantity, location and operational status require ledger-backed workflows.';

commit;
