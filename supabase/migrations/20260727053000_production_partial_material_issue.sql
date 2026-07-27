-- Allow production materials to be issued in multiple partial batches.
-- Additive and backward-compatible: legacy requirement movement links are preserved.
begin;

create table if not exists public.production_material_issues (
  id uuid primary key default gen_random_uuid(),
  requirement_id uuid not null references public.production_material_requirements(id) on delete restrict,
  inventory_movement_id uuid not null unique references public.inventory_movements(id) on delete restrict,
  quantity numeric not null check (quantity > 0),
  description text,
  issued_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  issued_at timestamptz not null default now()
);

create index if not exists production_material_issues_requirement_idx
  on public.production_material_issues(requirement_id,issued_at);

insert into public.production_material_issues(requirement_id,inventory_movement_id,quantity,description,issued_by,issued_at)
select r.id,r.inventory_movement_id,r.issued_quantity,'Legacy production material issue',r.created_by,r.created_at
from public.production_material_requirements r
where r.inventory_movement_id is not null and r.issued_quantity>0
on conflict (inventory_movement_id) do nothing;

alter table public.production_material_issues enable row level security;
revoke all on public.production_material_issues from public,anon,authenticated;

create or replace function private.protect_production_material_issue()
returns trigger language plpgsql set search_path='' as $$
begin
  raise exception 'Production material issue history is immutable';
end $$;

drop trigger if exists production_material_issue_immutable on public.production_material_issues;
create trigger production_material_issue_immutable
before update or delete on public.production_material_issues
for each row execute function private.protect_production_material_issue();

create or replace function public.issue_production_material(
  target_requirement uuid,
  issue_quantity numeric,
  issue_description text default null
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  actor uuid:=auth.uid();
  req record;
  remaining numeric;
  movement jsonb;
  movement_id uuid;
  saved public.production_material_requirements%rowtype;
  issue_row public.production_material_issues%rowtype;
begin
  if not private.production_action_allowed('production_material_issue') then
    raise exception using errcode='42501',message='Production material issue access required';
  end if;

  select r.*,o.project_id,o.status order_status
  into req
  from public.production_material_requirements r
  join public.production_orders o on o.id=r.production_order_id
  where r.id=target_requirement
  for update of r,o;

  if not found or req.order_status not in ('released','in_progress') then
    raise exception 'Released or in-progress production order required';
  end if;
  if req.project_id is null then raise exception 'Production order must be linked to a project'; end if;
  if issue_quantity is null or issue_quantity<=0 then raise exception 'Issue quantity must be greater than zero'; end if;

  remaining:=req.required_quantity-req.issued_quantity;
  if remaining<=0 then raise exception 'Material requirement is already fully issued'; end if;
  if issue_quantity>remaining then raise exception 'Issue quantity exceeds remaining requirement'; end if;

  movement:=public.issue_inventory_to_project(
    req.inventory_item_id,
    req.warehouse_id,
    req.project_id,
    issue_quantity,
    coalesce(nullif(btrim(issue_description),''),'Production material issue'),
    req.budget_item_id,
    req.milestone_id
  );
  movement_id:=(movement->>'id')::uuid;

  insert into public.production_material_issues(
    requirement_id,inventory_movement_id,quantity,description,issued_by
  ) values(
    req.id,movement_id,issue_quantity,nullif(btrim(issue_description),''),actor
  ) returning * into issue_row;

  update public.production_material_requirements
  set issued_quantity=issued_quantity+issue_quantity,
      consumed_quantity=consumed_quantity+issue_quantity,
      inventory_movement_id=coalesce(inventory_movement_id,movement_id)
  where id=req.id
  returning * into saved;

  update public.production_orders
  set status='in_progress',started_at=coalesce(started_at,now())
  where id=req.production_order_id and status='released';

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'production_material_issues',issue_row.id::text,'production_material_partial_issue',actor,
    to_jsonb(issue_row),
    jsonb_build_object(
      'requirement_id',req.id,
      'production_order_id',req.production_order_id,
      'required_quantity',req.required_quantity,
      'issued_quantity_after',saved.issued_quantity,
      'remaining_quantity',saved.required_quantity-saved.issued_quantity
    )
  );

  return jsonb_build_object(
    'requirement',to_jsonb(saved),
    'issue',to_jsonb(issue_row),
    'inventory_movement',movement,
    'remaining_quantity',saved.required_quantity-saved.issued_quantity
  );
end $$;

create or replace function public.cancel_production_order(target_order uuid,reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor uuid:=auth.uid();
  saved public.production_orders%rowtype;
  movement_id uuid;
begin
  if actor is null or public.current_identity_role()<>'owner' then raise exception 'Owner role required'; end if;
  if btrim(coalesce(reason,''))='' then raise exception 'Cancellation reason required'; end if;
  select * into saved from public.production_orders where id=target_order for update;
  if not found or saved.status in ('completed','cancelled') then raise exception 'Cancellable production order required'; end if;

  for movement_id in
    select distinct x.inventory_movement_id
    from (
      select i.inventory_movement_id
      from public.production_material_issues i
      join public.production_material_requirements r on r.id=i.requirement_id
      where r.production_order_id=target_order
      union all
      select r.inventory_movement_id
      from public.production_material_requirements r
      where r.production_order_id=target_order and r.inventory_movement_id is not null
    ) x
  loop
    if not exists(select 1 from public.inventory_movements where reversed_movement_id=movement_id) then
      perform public.reverse_inventory_movement(movement_id,reason);
    end if;
  end loop;

  update public.production_orders
  set status='cancelled',cancelled_at=now(),cancelled_by=actor,cancellation_reason=reason
  where id=target_order returning * into saved;
  return to_jsonb(saved);
end $$;

revoke all on function public.issue_production_material(uuid,numeric,text) from public,anon,authenticated;
grant execute on function public.issue_production_material(uuid,numeric,text) to authenticated;

commit;
