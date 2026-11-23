-- Align legacy Test schemas with Production's extensible project-cost source model.
-- New integrations add source_type values over time; a closed CHECK list blocks them.
alter table public.project_actual_cost_entries
  drop constraint if exists project_actual_cost_entries_source_type_check;
