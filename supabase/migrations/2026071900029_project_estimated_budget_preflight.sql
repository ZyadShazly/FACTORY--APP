-- Preflight for Estimated Budget migration 003.
-- Makes legacy project_costs rows uniquely addressable before the new
-- deduplication indexes are created by 003.

begin;

alter table public.project_costs add column if not exists source_type text;
alter table public.project_costs add column if not exists source_id uuid;
alter table public.project_costs add column if not exists source_line_reference text;
alter table public.project_costs add column if not exists allocation_revision integer;
alter table public.project_costs add column if not exists source_reference_key text;
alter table public.project_costs add column if not exists source_state text;
alter table public.project_costs add column if not exists source_metadata jsonb;

update public.project_costs
set source_type = coalesce(source_type, 'legacy'),
    source_id = case
      when coalesce(source_type, 'legacy') = 'legacy' then id
      else coalesce(source_id, reference_id, id)
    end,
    source_line_reference = coalesce(source_line_reference, 'main'),
    allocation_revision = coalesce(allocation_revision, 1),
    source_reference_key = coalesce(source_reference_key, 'legacy:project_costs:' || id::text),
    source_state = coalesce(source_state, 'legacy_import'),
    source_metadata = coalesce(source_metadata, '{}'::jsonb)
where source_type is null
   or source_id is null
   or source_line_reference is null
   or allocation_revision is null
   or source_reference_key is null
   or source_state is null
   or source_metadata is null;

commit;
