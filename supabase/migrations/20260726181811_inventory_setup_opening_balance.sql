-- Inventory setup and opening-balance workflow.
-- Additive only: existing catalog rows, balances, movements, and procurement flows are preserved.
begin;

alter table public.materials
  add column if not exists active boolean not null default true;

create table public.opening_inventory_documents (
  id uuid primary key default gen_random_uuid(),
  document_number text not null unique default (
    'OB-' || to_char(clock_timestamp(),'YYMMDD') || '-' ||
    upper(substr(encode(extensions.gen_random_bytes(5),'hex'),1,8))
  ),
  status text not null default 'draft' check (status in ('draft','posted')),
  reference text,
  reason text,
  created_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  approved_by uuid references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  approved_at timestamptz,
  check (status='draft' or (approved_by is not null and approved_at is not null))
);

create table public.opening_inventory_lines (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.opening_inventory_documents(id) on delete restrict,
  inventory_item_id uuid not null references public.inventory_items(id) on delete restrict,
  warehouse_id uuid not null references public.inventory_warehouses(id) on delete restrict,
  location_id uuid references public.inventory_locations(id) on delete restrict,
  quantity numeric not null check (quantity>0),
  unit_cost numeric not null default 0 check (unit_cost>=0),
  total_value numeric generated always as (round(quantity*unit_cost,2)) stored,
  reference text,
  reason text,
  created_at timestamptz not null default now(),
  unique nulls not distinct (document_id,inventory_item_id,warehouse_id,location_id)
);

create index opening_inventory_documents_status_created_idx
  on public.opening_inventory_documents(status,created_at desc);
create index opening_inventory_lines_document_idx
  on public.opening_inventory_lines(document_id);

alter table public.inventory_movements
  add column if not exists opening_inventory_line_id uuid
  references public.opening_inventory_lines(id) on delete restrict;

alter table public.inventory_movements
  drop constraint if exists inventory_movements_movement_type_check;
alter table public.inventory_movements
  drop constraint if exists inventory_movements_direction_check;
alter table public.inventory_movements
  add constraint inventory_movements_movement_type_check
  check (movement_type in (
    'receipt','project_issue','receipt_reversal','project_issue_reversal',
    'adjustment_in','adjustment_out','transfer_in','transfer_out',
    'production_return','waste_out','damage_out','opening_balance'
  ));
alter table public.inventory_movements
  add constraint inventory_movements_direction_check
  check (
    (movement_type in (
      'receipt','project_issue_reversal','adjustment_in','transfer_in',
      'production_return','opening_balance'
    ) and quantity_delta>0)
    or
    (movement_type in (
      'project_issue','receipt_reversal','adjustment_out','transfer_out',
      'waste_out','damage_out'
    ) and quantity_delta<0)
  );

create unique index inventory_opening_line_once_idx
  on public.inventory_movements(opening_inventory_line_id)
  where opening_inventory_line_id is not null;

alter table public.opening_inventory_documents enable row level security;
alter table public.opening_inventory_lines enable row level security;
revoke all on public.opening_inventory_documents,public.opening_inventory_lines
  from public,anon,authenticated;

create or replace function private.protect_opening_inventory_document()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if tg_op='DELETE' and old.status='posted' then
    raise exception 'Posted opening inventory cannot be deleted';
  end if;
  if tg_op='UPDATE' and old.status='posted' then
    raise exception 'Posted opening inventory is immutable';
  end if;
  return case when tg_op='DELETE' then old else new end;
end $$;

create trigger opening_inventory_document_immutable
before update or delete on public.opening_inventory_documents
for each row execute function private.protect_opening_inventory_document();

create or replace function private.protect_opening_inventory_line()
returns trigger
language plpgsql
set search_path=''
as $$
declare parent_status text;
begin
  select d.status into parent_status
  from public.opening_inventory_documents d
  where d.id=coalesce(old.document_id,new.document_id);
  if parent_status<>'draft' then
    raise exception 'Posted opening inventory lines are immutable';
  end if;
  return case when tg_op='DELETE' then old else new end;
end $$;

create trigger opening_inventory_line_immutable
before update or delete on public.opening_inventory_lines
for each row execute function private.protect_opening_inventory_line();

create or replace function public.create_inventory_item(
  item_sku text,
  item_name text,
  item_unit text,
  target_material uuid default null,
  item_active boolean default true
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  actor uuid:=auth.uid();
  saved public.inventory_items%rowtype;
begin
  if not private.inventory_manage_allowed() then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if btrim(coalesce(item_sku,''))='' then raise exception 'Inventory SKU is required'; end if;
  if btrim(coalesce(item_name,''))='' then raise exception 'Inventory item name is required'; end if;
  if btrim(coalesce(item_unit,''))='' then raise exception 'Inventory item unit is required'; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(lower(btrim(item_sku)),0)
  );
  if exists(
    select 1 from public.inventory_items i
    where lower(btrim(i.sku))=lower(btrim(item_sku))
  ) then
    raise exception 'Inventory SKU already exists';
  end if;
  if target_material is not null and not exists(
    select 1 from public.materials m where m.id=target_material and m.active
  ) then
    raise exception 'Active raw material is required';
  end if;
  if target_material is not null and exists(
    select 1 from public.inventory_items i where i.material_id=target_material
  ) then
    raise exception 'Material is already linked to another inventory item';
  end if;

  insert into public.inventory_items(sku,name,unit,material_id,active)
  values(btrim(item_sku),btrim(item_name),btrim(item_unit),target_material,coalesce(item_active,true))
  returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'inventory_items',saved.id::text,'inventory_item_created',actor,to_jsonb(saved),
    jsonb_build_object('source','inventory_setup','created_from_material',target_material is not null)
  );
  return to_jsonb(saved);
exception
  when unique_violation then
    if exists(select 1 from public.inventory_items i where lower(btrim(i.sku))=lower(btrim(item_sku))) then
      raise exception 'Inventory SKU already exists';
    end if;
    raise exception 'Material is already linked to another inventory item';
end $$;

create or replace function public.manage_inventory_item_catalog(
  target_item uuid,
  target_material uuid,
  target_active boolean
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  actor uuid:=auth.uid();
  saved public.inventory_items%rowtype;
  old_row public.inventory_items%rowtype;
begin
  if not private.inventory_manage_allowed() then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  select * into old_row from public.inventory_items where id=target_item for update;
  if not found then raise exception 'Inventory item not found'; end if;
  if target_material is not null and not exists(
    select 1 from public.materials where id=target_material and active
  ) then
    raise exception 'Active raw material is required';
  end if;
  if target_active=false and old_row.active and exists(
    select 1 from public.inventory_balances b
    where b.inventory_item_id=target_item and b.quantity_on_hand<>0
  ) then
    raise exception 'Cannot deactivate an inventory item with stock';
  end if;
  if target_material is not null and exists(
    select 1 from public.inventory_items i
    where i.material_id=target_material and i.id<>target_item
  ) then
    raise exception 'Material is already linked to another inventory item';
  end if;

  update public.inventory_items
  set material_id=target_material,active=coalesce(target_active,active)
  where id=target_item
  returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values(
    'inventory_items',saved.id::text,'inventory_catalog_updated',actor,
    to_jsonb(old_row),to_jsonb(saved),
    jsonb_build_object(
      'source','inventory_setup',
      'material_link_changed',old_row.material_id is distinct from saved.material_id,
      'active_changed',old_row.active is distinct from saved.active
    )
  );
  return to_jsonb(saved);
end $$;

create or replace function public.set_material_active(
  target_material uuid,
  target_active boolean
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  actor uuid:=auth.uid();
  old_row public.materials%rowtype;
  saved public.materials%rowtype;
begin
  if not private.inventory_manage_allowed() then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  select * into old_row from public.materials where id=target_material for update;
  if not found then raise exception 'Raw material not found'; end if;
  update public.materials set active=coalesce(target_active,active)
  where id=target_material returning * into saved;
  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values(
    'materials',saved.id::text,'material_status_changed',actor,
    to_jsonb(old_row),to_jsonb(saved),jsonb_build_object('source','inventory_setup')
  );
  return to_jsonb(saved);
end $$;

create or replace function public.delete_inventory_setup_entity(
  entity_type text,
  target_id uuid,
  deletion_reason text
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  actor uuid:=auth.uid();
  item_row public.inventory_items%rowtype;
  material_row public.materials%rowtype;
  blockers text[]:='{}'::text[];
begin
  if not private.inventory_manage_allowed() then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if btrim(coalesce(deletion_reason,''))='' then raise exception 'Deletion reason is required'; end if;

  if entity_type='inventory_item' then
    select * into item_row from public.inventory_items where id=target_id for update;
    if not found then raise exception 'Inventory item not found'; end if;
    if item_row.material_id is not null and exists(select 1 from public.material_purchases where material_id=item_row.material_id) then blockers:=array_append(blockers,'material_purchases'); end if;
    if item_row.material_id is not null and exists(select 1 from public.purchase_request_items where material_id=item_row.material_id) then blockers:=array_append(blockers,'purchase_request_items'); end if;
    if item_row.material_id is not null and exists(select 1 from public.purchase_order_items where material_id=item_row.material_id) then blockers:=array_append(blockers,'purchase_order_items'); end if;
    if item_row.material_id is not null and exists(
      select 1 from public.supplier_quote_items qi
      join public.purchase_request_items ri on ri.id=qi.purchase_request_item_id
      where ri.material_id=item_row.material_id
    ) then blockers:=array_append(blockers,'supplier_quote_items'); end if;
    if item_row.material_id is not null and exists(
      select 1 from public.goods_receipt_items gi
      join public.purchase_order_items oi on oi.id=gi.purchase_order_item_id
      where oi.material_id=item_row.material_id
    ) then blockers:=array_append(blockers,'goods_receipt_items'); end if;
    if exists(select 1 from public.inventory_movements where inventory_item_id=target_id) then blockers:=array_append(blockers,'inventory_movements'); end if;
    if exists(select 1 from public.inventory_balances where inventory_item_id=target_id) then blockers:=array_append(blockers,'inventory_balances'); end if;
    if exists(select 1 from public.production_material_requirements where inventory_item_id=target_id) then blockers:=array_append(blockers,'production_usage'); end if;
    if exists(
      select 1 from public.inventory_movements m
      join public.project_actual_cost_entries c on c.id=m.actual_cost_entry_id
      where m.inventory_item_id=target_id
    ) then blockers:=array_append(blockers,'actual_cost_records'); end if;
    if exists(select 1 from public.opening_inventory_lines where inventory_item_id=target_id) then blockers:=array_append(blockers,'opening_inventory'); end if;
    if cardinality(blockers)>0 then
      raise exception 'Inventory item has operational references; deactivate it instead';
    end if;
    insert into public.audit_log(table_name,record_id,action,actor_id,old_data,metadata)
    values(
      'inventory_items',item_row.id::text,'inventory_item_deleted',actor,to_jsonb(item_row),
      jsonb_build_object('source','inventory_setup','reason',btrim(deletion_reason))
    );
    delete from public.inventory_items where id=target_id;
    return jsonb_build_object('deleted',true,'entity_type',entity_type,'id',target_id);
  elsif entity_type='material' then
    select * into material_row from public.materials where id=target_id for update;
    if not found then raise exception 'Raw material not found'; end if;
    if exists(select 1 from public.inventory_items where material_id=target_id) then blockers:=array_append(blockers,'inventory_items'); end if;
    if exists(select 1 from public.material_purchases where material_id=target_id) then blockers:=array_append(blockers,'material_purchases'); end if;
    if exists(select 1 from public.purchase_request_items where material_id=target_id) then blockers:=array_append(blockers,'purchase_request_items'); end if;
    if exists(select 1 from public.purchase_order_items where material_id=target_id) then blockers:=array_append(blockers,'purchase_order_items'); end if;
    if exists(
      select 1 from public.supplier_quote_items qi
      join public.purchase_request_items ri on ri.id=qi.purchase_request_item_id
      where ri.material_id=target_id
    ) then blockers:=array_append(blockers,'supplier_quote_items'); end if;
    if exists(
      select 1 from public.goods_receipt_items gi
      join public.purchase_order_items oi on oi.id=gi.purchase_order_item_id
      where oi.material_id=target_id
    ) then blockers:=array_append(blockers,'goods_receipt_items'); end if;
    if exists(
      select 1 from public.supplier_invoice_lines sil
      join public.purchase_order_items oi on oi.id=sil.purchase_order_item_id
      where oi.material_id=target_id and sil.actual_cost_entry_id is not null
    ) then blockers:=array_append(blockers,'actual_cost_records'); end if;
    if exists(
      select 1 from public.production_material_requirements pmr
      join public.inventory_items i on i.id=pmr.inventory_item_id
      where i.material_id=target_id
    ) then blockers:=array_append(blockers,'production_usage'); end if;
    if exists(
      select 1 from public.products p,
      lateral jsonb_array_elements(coalesce(p.bom,'[]'::jsonb)) component
      where component->>'material_id'=target_id::text
    ) then blockers:=array_append(blockers,'production_bom'); end if;
    if cardinality(blockers)>0 then
      raise exception 'Raw material has operational references; archive it instead';
    end if;
    insert into public.audit_log(table_name,record_id,action,actor_id,old_data,metadata)
    values(
      'materials',material_row.id::text,'material_deleted',actor,to_jsonb(material_row),
      jsonb_build_object('source','inventory_setup','reason',btrim(deletion_reason))
    );
    delete from public.materials where id=target_id;
    return jsonb_build_object('deleted',true,'entity_type',entity_type,'id',target_id);
  end if;
  raise exception 'Unsupported setup entity type';
end $$;

create or replace function public.create_opening_inventory_document(
  document_reference text default null,
  document_reason text default null
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  actor uuid:=auth.uid();
  saved public.opening_inventory_documents%rowtype;
begin
  if not private.inventory_manage_allowed() then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  insert into public.opening_inventory_documents(reference,reason,created_by)
  values(nullif(btrim(document_reference),''),nullif(btrim(document_reason),''),actor)
  returning * into saved;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'opening_inventory_documents',saved.id::text,'opening_inventory_draft_created',
    actor,to_jsonb(saved),jsonb_build_object('source','opening_inventory')
  );
  return to_jsonb(saved);
end $$;

create or replace function public.save_opening_inventory_line(
  target_document uuid,
  target_line uuid,
  target_inventory_item uuid,
  target_warehouse uuid,
  target_location uuid,
  opening_quantity numeric,
  opening_unit_cost numeric,
  line_reference text,
  line_reason text
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  actor uuid:=auth.uid();
  old_row public.opening_inventory_lines%rowtype;
  saved public.opening_inventory_lines%rowtype;
begin
  if not private.inventory_manage_allowed() then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if not exists(
    select 1 from public.opening_inventory_documents
    where id=target_document and status='draft' for update
  ) then raise exception 'Draft opening inventory document required'; end if;
  if opening_quantity is null or opening_quantity<=0 then raise exception 'Opening quantity must be greater than zero'; end if;
  if opening_unit_cost is null or opening_unit_cost<0 then raise exception 'Opening unit cost cannot be negative'; end if;
  if not exists(select 1 from public.inventory_items where id=target_inventory_item and active) then
    raise exception 'Active inventory item required';
  end if;
  if not exists(select 1 from public.inventory_warehouses where id=target_warehouse and active) then
    raise exception 'Active warehouse required';
  end if;
  if target_location is not null and not exists(
    select 1 from public.inventory_locations
    where id=target_location and warehouse_id=target_warehouse and active
  ) then raise exception 'Active warehouse location required'; end if;

  if target_line is null then
    insert into public.opening_inventory_lines(
      document_id,inventory_item_id,warehouse_id,location_id,quantity,unit_cost,reference,reason
    ) values(
      target_document,target_inventory_item,target_warehouse,target_location,
      opening_quantity,opening_unit_cost,nullif(btrim(line_reference),''),
      nullif(btrim(line_reason),'')
    ) returning * into saved;
  else
    select * into old_row from public.opening_inventory_lines
    where id=target_line and document_id=target_document for update;
    if not found then raise exception 'Opening inventory line not found'; end if;
    update public.opening_inventory_lines set
      inventory_item_id=target_inventory_item,
      warehouse_id=target_warehouse,
      location_id=target_location,
      quantity=opening_quantity,
      unit_cost=opening_unit_cost,
      reference=nullif(btrim(line_reference),''),
      reason=nullif(btrim(line_reason),'')
    where id=target_line returning * into saved;
  end if;

  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values(
    'opening_inventory_lines',saved.id::text,
    case when target_line is null then 'opening_inventory_line_created' else 'opening_inventory_line_updated' end,
    actor,case when target_line is null then null else to_jsonb(old_row) end,to_jsonb(saved),
    jsonb_build_object('source','opening_inventory','document_id',target_document)
  );
  return to_jsonb(saved);
exception
  when unique_violation then
    raise exception 'The item, warehouse, and location already exist in this opening document';
end $$;

create or replace function public.delete_opening_inventory_line(
  target_line uuid,
  deletion_reason text
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  actor uuid:=auth.uid();
  old_row public.opening_inventory_lines%rowtype;
begin
  if not private.inventory_manage_allowed() then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if btrim(coalesce(deletion_reason,''))='' then raise exception 'Deletion reason is required'; end if;
  select l.* into old_row
  from public.opening_inventory_lines l
  join public.opening_inventory_documents d on d.id=l.document_id
  where l.id=target_line and d.status='draft'
  for update of l,d;
  if not found then raise exception 'Draft opening inventory line required'; end if;
  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,metadata)
  values(
    'opening_inventory_lines',old_row.id::text,'opening_inventory_line_deleted',
    actor,to_jsonb(old_row),
    jsonb_build_object('source','opening_inventory','reason',btrim(deletion_reason))
  );
  delete from public.opening_inventory_lines where id=target_line;
  return jsonb_build_object('deleted',true,'id',target_line);
end $$;

create or replace function public.post_opening_inventory_document(
  target_document uuid
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  actor uuid:=auth.uid();
  document_row public.opening_inventory_documents%rowtype;
  saved public.opening_inventory_documents%rowtype;
  movement_row public.inventory_movements%rowtype;
  line record;
  movement_count integer:=0;
begin
  if not private.inventory_manage_allowed() then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  select * into document_row from public.opening_inventory_documents
  where id=target_document for update;
  if not found then raise exception 'Opening inventory document not found'; end if;
  if document_row.status<>'draft' then raise exception 'Opening inventory document is already posted'; end if;
  if not exists(select 1 from public.opening_inventory_lines where document_id=target_document) then
    raise exception 'Opening inventory document requires at least one line';
  end if;

  for line in
    select l.* from public.opening_inventory_lines l
    where l.document_id=target_document order by l.created_at,l.id
  loop
    if not exists(select 1 from public.inventory_items where id=line.inventory_item_id and active) then
      raise exception 'Active inventory item required';
    end if;
    if not exists(select 1 from public.inventory_warehouses where id=line.warehouse_id and active) then
      raise exception 'Active warehouse required';
    end if;
    if line.location_id is not null and not exists(
      select 1 from public.inventory_locations
      where id=line.location_id and warehouse_id=line.warehouse_id and active
    ) then raise exception 'Active warehouse location required'; end if;

    insert into public.inventory_movements(
      movement_type,inventory_item_id,warehouse_id,location_id,quantity_delta,
      unit_cost,opening_inventory_line_id,reason,posted_by,metadata
    ) values(
      'opening_balance',line.inventory_item_id,line.warehouse_id,line.location_id,
      line.quantity,line.unit_cost,line.id,
      coalesce(line.reason,document_row.reason,'Opening inventory'),
      actor,jsonb_build_object(
        'source','opening_inventory',
        'document_id',target_document,
        'document_number',document_row.document_number,
        'document_reference',document_row.reference,
        'line_reference',line.reference
      )
    ) returning * into movement_row;
    insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
    values(
      'inventory_movements',movement_row.id::text,'opening_balance_movement_posted',
      actor,to_jsonb(movement_row),
      jsonb_build_object(
        'source','opening_inventory',
        'document_id',target_document,
        'opening_inventory_line_id',line.id
      )
    );
    movement_count:=movement_count+1;
  end loop;

  update public.opening_inventory_documents
  set status='posted',approved_by=actor,approved_at=now()
  where id=target_document returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values(
    'opening_inventory_documents',saved.id::text,'opening_inventory_posted',
    actor,to_jsonb(document_row),to_jsonb(saved),
    jsonb_build_object(
      'source','opening_inventory',
      'movement_count',movement_count,
      'total_quantity',(select sum(quantity) from public.opening_inventory_lines where document_id=target_document),
      'total_value',(select sum(total_value) from public.opening_inventory_lines where document_id=target_document)
    )
  );
  return jsonb_build_object('document',to_jsonb(saved),'movement_count',movement_count);
exception
  when unique_violation then
    raise exception 'Opening inventory document is already posted';
end $$;

create or replace function public.get_inventory_workspace()
returns jsonb
language plpgsql security definer set search_path='' as $$
declare role_name text:=public.current_identity_role();
begin
  if auth.uid() is null or role_name not in ('owner','manager','accountant','production') then
    raise exception using errcode='42501',message='Inventory access required';
  end if;
  return jsonb_build_object(
    'items',coalesce((select jsonb_agg(to_jsonb(i) order by i.name) from public.inventory_items i where i.active),'[]'::jsonb),
    'catalog',coalesce((select jsonb_agg(to_jsonb(x) order by x.active desc,x.name) from (
      select i.*,m.name material_name from public.inventory_items i left join public.materials m on m.id=i.material_id
    ) x),'[]'::jsonb),
    'materials',coalesce((select jsonb_agg(to_jsonb(m) order by m.active desc,m.name) from public.materials m),'[]'::jsonb),
    'unlinked_materials',coalesce((select jsonb_agg(to_jsonb(m) order by m.name)
      from public.materials m left join public.inventory_items i on i.material_id=m.id
      where m.active and i.id is null),'[]'::jsonb),
    'warehouses',coalesce((select jsonb_agg(to_jsonb(w) order by w.name) from public.inventory_warehouses w where w.active),'[]'::jsonb),
    'warehouse_admin',coalesce((select jsonb_agg(to_jsonb(w) order by w.active desc,w.name) from public.inventory_warehouses w),'[]'::jsonb),
    'locations',coalesce((select jsonb_agg(to_jsonb(l) order by l.warehouse_id,l.name) from public.inventory_locations l where l.active),'[]'::jsonb),
    'balances',coalesce((select jsonb_agg(to_jsonb(x) order by x.item_name,x.warehouse_name) from (
      select b.*,i.name item_name,i.sku,i.unit,w.name warehouse_name,
        case when b.quantity_on_hand=0 then 0 else b.inventory_value/nullif(b.quantity_on_hand,0) end average_unit_cost
      from public.inventory_balances b
      join public.inventory_items i on i.id=b.inventory_item_id
      join public.inventory_warehouses w on w.id=b.warehouse_id
    ) x),'[]'::jsonb),
    'movements',coalesce((select jsonb_agg(to_jsonb(x) order by x.posted_at desc) from (
      select m.*,i.name item_name,w.name warehouse_name
      from public.inventory_movements m
      join public.inventory_items i on i.id=m.inventory_item_id
      join public.inventory_warehouses w on w.id=m.warehouse_id
      order by m.posted_at desc limit 100
    ) x),'[]'::jsonb),
    'count_sessions',coalesce((select jsonb_agg(to_jsonb(s) order by s.created_at desc) from public.inventory_count_sessions s),'[]'::jsonb),
    'count_lines',coalesce((select jsonb_agg(to_jsonb(l) order by l.session_id,i.name)
      from public.inventory_count_lines l join public.inventory_items i on i.id=l.inventory_item_id),'[]'::jsonb),
    'opening_documents',coalesce((select jsonb_agg(to_jsonb(d) order by d.created_at desc)
      from public.opening_inventory_documents d),'[]'::jsonb),
    'opening_lines',coalesce((select jsonb_agg(to_jsonb(x) order by x.document_id,x.created_at) from (
      select l.*,i.name item_name,i.sku,i.unit,w.name warehouse_name,loc.name location_name
      from public.opening_inventory_lines l
      join public.inventory_items i on i.id=l.inventory_item_id
      join public.inventory_warehouses w on w.id=l.warehouse_id
      left join public.inventory_locations loc on loc.id=l.location_id
    ) x),'[]'::jsonb),
    'capabilities',jsonb_build_object(
      'manage',private.inventory_manage_allowed(),
      'production_event',role_name in ('owner','manager','production'),
      'view_financials',role_name in ('owner','manager','accountant')
    )
  );
end $$;

revoke all on function public.create_inventory_item(text,text,text,uuid,boolean) from public,anon,authenticated;
revoke all on function public.manage_inventory_item_catalog(uuid,uuid,boolean) from public,anon,authenticated;
revoke all on function public.set_material_active(uuid,boolean) from public,anon,authenticated;
revoke all on function public.delete_inventory_setup_entity(text,uuid,text) from public,anon,authenticated;
revoke all on function public.create_opening_inventory_document(text,text) from public,anon,authenticated;
revoke all on function public.save_opening_inventory_line(uuid,uuid,uuid,uuid,uuid,numeric,numeric,text,text) from public,anon,authenticated;
revoke all on function public.delete_opening_inventory_line(uuid,text) from public,anon,authenticated;
revoke all on function public.post_opening_inventory_document(uuid) from public,anon,authenticated;

grant execute on function public.create_inventory_item(text,text,text,uuid,boolean) to authenticated;
grant execute on function public.manage_inventory_item_catalog(uuid,uuid,boolean) to authenticated;
grant execute on function public.set_material_active(uuid,boolean) to authenticated;
grant execute on function public.delete_inventory_setup_entity(text,uuid,text) to authenticated;
grant execute on function public.create_opening_inventory_document(text,text) to authenticated;
grant execute on function public.save_opening_inventory_line(uuid,uuid,uuid,uuid,uuid,numeric,numeric,text,text) to authenticated;
grant execute on function public.delete_opening_inventory_line(uuid,text) to authenticated;
grant execute on function public.post_opening_inventory_document(uuid) to authenticated;

commit;
