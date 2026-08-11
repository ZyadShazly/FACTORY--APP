-- Project documents are operational records. Archive metadata and retain the
-- storage object; physical cleanup is an explicit future retention operation.

alter table public.project_files
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid references public.profiles(id) on delete set null,
  add column if not exists archive_reason text;

create index if not exists project_files_project_active_idx
  on public.project_files(project_id, category, created_at)
  where archived_at is null;

create or replace function public.protect_project_file_history()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Project files cannot be deleted; archive the file to preserve project history' using errcode = '23514';
  end if;
  if new.archived_at is distinct from old.archived_at
     or new.archived_by is distinct from old.archived_by
     or new.archive_reason is distinct from old.archive_reason then
    if current_setting('app.project_file_archive_rpc', true) <> 'on' then
      raise exception 'Project file archive state must be changed through the protected workflow' using errcode = '42501';
    end if;
  end if;
  return new;
end
$$;

revoke all on function public.protect_project_file_history() from public, anon, authenticated;
drop trigger if exists protect_project_file_history on public.project_files;
create trigger protect_project_file_history
before update of archived_at, archived_by, archive_reason or delete on public.project_files
for each row execute function public.protect_project_file_history();

create or replace function public.archive_project_file(target_file uuid, reason text)
returns public.project_files
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare actor uuid := auth.uid(); file_row public.project_files%rowtype; saved public.project_files%rowtype;
begin
  if actor is null or not private.project_has_permission('project_files_delete') then
    raise exception 'project_files_delete permission required' using errcode = '42501';
  end if;
  if btrim(coalesce(reason, '')) = '' then raise exception 'Archive reason is required' using errcode = '23514'; end if;
  select * into file_row from public.project_files where id = target_file for update;
  if file_row.id is null then raise exception 'Project file not found' using errcode = 'P0002'; end if;
  if not private.project_can_view(file_row.project_id) then raise exception 'Project access denied' using errcode = '42501'; end if;
  if file_row.archived_at is not null then return file_row; end if;
  perform set_config('app.project_file_archive_rpc', 'on', true);
  update public.project_files
  set archived_at = now(), archived_by = actor, archive_reason = btrim(reason)
  where id = target_file returning * into saved;
  perform set_config('app.project_file_archive_rpc', 'off', true);
  insert into public.project_activities(project_id, actor_id, action_type, description, metadata)
  values(saved.project_id, actor, 'file_archived', 'تمت أرشفة ملف من المشروع',
    jsonb_build_object('file_id', saved.id, 'file_name', saved.file_name, 'reason', saved.archive_reason, 'storage_retained', true));
  insert into public.audit_log(table_name, record_id, action, actor_id, old_data, new_data, metadata)
  values('project_files', saved.id::text, 'archive', actor, to_jsonb(file_row), to_jsonb(saved),
    jsonb_build_object('reason', saved.archive_reason, 'storage_retained', true));
  return saved;
end
$$;

create or replace function public.restore_project_file(target_file uuid, reason text)
returns public.project_files
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare actor uuid := auth.uid(); file_row public.project_files%rowtype; saved public.project_files%rowtype;
begin
  if actor is null or not private.project_has_permission('project_files_delete') then
    raise exception 'project_files_delete permission required' using errcode = '42501';
  end if;
  if btrim(coalesce(reason, '')) = '' then raise exception 'Restore reason is required' using errcode = '23514'; end if;
  select * into file_row from public.project_files where id = target_file for update;
  if file_row.id is null then raise exception 'Project file not found' using errcode = 'P0002'; end if;
  if not private.project_can_view(file_row.project_id) then raise exception 'Project access denied' using errcode = '42501'; end if;
  if file_row.archived_at is null then return file_row; end if;
  perform set_config('app.project_file_archive_rpc', 'on', true);
  update public.project_files set archived_at = null, archived_by = null, archive_reason = null
  where id = target_file returning * into saved;
  perform set_config('app.project_file_archive_rpc', 'off', true);
  insert into public.project_activities(project_id, actor_id, action_type, description, metadata)
  values(saved.project_id, actor, 'file_restored', 'تمت استعادة ملف مؤرشف إلى المشروع',
    jsonb_build_object('file_id', saved.id, 'file_name', saved.file_name, 'reason', btrim(reason)));
  insert into public.audit_log(table_name, record_id, action, actor_id, old_data, new_data, metadata)
  values('project_files', saved.id::text, 'restore', actor, to_jsonb(file_row), to_jsonb(saved), jsonb_build_object('reason', btrim(reason)));
  return saved;
end
$$;

revoke all on function public.archive_project_file(uuid, text) from public, anon;
revoke all on function public.restore_project_file(uuid, text) from public, anon;
grant execute on function public.archive_project_file(uuid, text) to authenticated;
grant execute on function public.restore_project_file(uuid, text) to authenticated;

drop policy if exists project_files_delete on public.project_files;
revoke delete on public.project_files from anon, authenticated;
drop policy if exists project_files_storage_delete on storage.objects;

comment on function public.archive_project_file(uuid, text) is
  'Archives project-file metadata without deleting the private storage object; records project activity and audit history.';
