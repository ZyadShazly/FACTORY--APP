-- Cover the actor foreign keys introduced by the daily-labor correction workflow.
begin;

create index if not exists daily_labor_last_corrected_by_idx
  on public.daily_labor(last_corrected_by)
  where last_corrected_by is not null;

create index if not exists daily_labor_corrections_corrected_by_idx
  on public.daily_labor_corrections(corrected_by)
  where corrected_by is not null;

commit;
