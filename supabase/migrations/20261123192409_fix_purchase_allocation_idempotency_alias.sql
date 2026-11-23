-- Fix variable/SQL-alias ambiguity on idempotent replay of purchase allocations.
create or replace function public.save_purchase_invoice_project_allocations(
  target_invoice_id uuid, target_allocations jsonb
)
returns jsonb language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
declare
  actor uuid:=auth.uid();
  invoice public.supplier_invoices%rowtype;
  source_po public.purchase_orders%rowtype;
  line record;
  item jsonb;
  allocation jsonb;
  project_id_value uuid;
  allocation_amount numeric(18,2);
  line_total_allocated numeric(18,2);
  allocation_id uuid;
  line_allocations jsonb;
  result jsonb;
begin
  if actor is null or public.current_identity_role() not in ('owner','manager','accountant') then
    raise exception 'Owner, manager, or accountant role required';
  end if;
  if coalesce(jsonb_typeof(target_allocations),'')<>'array' or coalesce(jsonb_array_length(target_allocations),0)=0 then
    raise exception 'Invoice line project allocations are required';
  end if;
  if (select count(*) from jsonb_array_elements(target_allocations)) <>
     (select count(distinct (value->>'purchase_order_item_id')::uuid) from jsonb_array_elements(target_allocations)) then
    raise exception 'Duplicate purchase order item allocation payload';
  end if;
  select * into invoice from public.supplier_invoices
  where id=target_invoice_id for update;
  if not found or invoice.status not in ('approved','paid') then
    raise exception 'Approved supplier invoice required';
  end if;
  select * into source_po from public.purchase_orders where id=invoice.purchase_order_id;
  if source_po.project_id is not null then
    raise exception 'Use the existing direct-project cost workflow for project purchase orders';
  end if;
  if exists(select 1 from public.purchase_line_project_allocations a
    join public.supplier_invoice_lines sil on sil.id=a.supplier_invoice_line_id
    where sil.supplier_invoice_id=target_invoice_id and a.actual_cost_entry_id is not null) then
    if (select count(*) from public.purchase_line_project_allocations a
        join public.supplier_invoice_lines sil on sil.id=a.supplier_invoice_line_id
        where sil.supplier_invoice_id=target_invoice_id) <>
       (select coalesce(sum(jsonb_array_length(value->'allocations')),0)
        from jsonb_array_elements(target_allocations))
       or exists(
         select 1 from jsonb_array_elements(target_allocations) payload_line
         cross join jsonb_array_elements(payload_line->'allocations') expected
         where not exists(
           select 1 from public.supplier_invoice_lines sil
           join public.purchase_line_project_allocations a on a.supplier_invoice_line_id=sil.id
           where sil.supplier_invoice_id=target_invoice_id
             and sil.purchase_order_item_id=(payload_line->>'purchase_order_item_id')::uuid
             and a.project_id=(expected->>'project_id')::uuid
             and a.allocated_amount=round((expected->>'allocated_amount')::numeric,2)
             and a.actual_cost_entry_id is not null
         )
       ) then
      raise exception 'Invoice already has different submitted project allocations; reverse them before changing amounts';
    end if;
    select coalesce(jsonb_agg(to_jsonb(cost_entry) order by cost_entry.id),'[]'::jsonb)
    into result
    from public.purchase_line_project_allocations a
    join public.supplier_invoice_lines sil on sil.id=a.supplier_invoice_line_id
    join public.project_actual_cost_entries cost_entry on cost_entry.id=a.actual_cost_entry_id
    where sil.supplier_invoice_id=target_invoice_id;
    return jsonb_build_object('invoice_id',target_invoice_id,'entries',result,
      'created_count',jsonb_array_length(result),'allocations_saved',true,'idempotent_replay',true);
  end if;
  delete from public.purchase_line_project_allocations a
  using public.supplier_invoice_lines sil
  where a.supplier_invoice_line_id=sil.id and sil.supplier_invoice_id=target_invoice_id;

  for line in
    select sil.* from public.supplier_invoice_lines sil
    where sil.supplier_invoice_id=target_invoice_id order by sil.id
  loop
    select value into item from jsonb_array_elements(target_allocations)
    where (value->>'purchase_order_item_id')::uuid=line.purchase_order_item_id
    limit 1;
    if item is null then
      raise exception 'Every invoice line must have a project allocation';
    end if;
    line_allocations:=item->'allocations';
    if jsonb_typeof(line_allocations)<>'array' or jsonb_array_length(line_allocations)=0 then
      raise exception 'Every invoice line must include at least one project';
    end if;
    line_total_allocated:=0;
    for allocation in select * from jsonb_array_elements(line_allocations)
    loop
      project_id_value:=(allocation->>'project_id')::uuid;
      allocation_amount:=round((allocation->>'allocated_amount')::numeric,2);
      if allocation_amount<=0 then raise exception 'Allocated project amounts must be positive'; end if;
      perform 1 from public.projects
      where id=project_id_value and lifecycle not in ('closed','cancelled') for update;
      if not found or not private.project_can_view(project_id_value) then
        raise exception 'Project is unavailable or access denied';
      end if;
      insert into public.purchase_line_project_allocations(
        supplier_invoice_line_id,project_id,allocation_method,allocation_value,allocated_amount,created_by
      ) values(
        line.id,project_id_value,'fixed_amount',allocation_amount,allocation_amount,actor
      ) returning id into allocation_id;
      line_total_allocated:=line_total_allocated+allocation_amount;
    end loop;
    if round(line_total_allocated,2)<>round(
      coalesce(line.line_total,(line.quantity*line.unit_price)-line.discount_amount+line.tax_amount)
      *invoice.exchange_rate,2
    ) then
      raise exception 'Project allocations must equal invoice line total in base currency for PO item %',line.purchase_order_item_id;
    end if;
  end loop;

  result:=public.prepare_purchase_line_project_costs(target_invoice_id);
  return result||jsonb_build_object('allocations_saved',true);
end
$$;

revoke all on function public.save_purchase_invoice_project_allocations(uuid,jsonb) from public,anon;
grant execute on function public.save_purchase_invoice_project_allocations(uuid,jsonb) to authenticated;
