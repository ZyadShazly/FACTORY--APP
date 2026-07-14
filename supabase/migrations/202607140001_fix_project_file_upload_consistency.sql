-- Keep project file storage, metadata, visibility, and activity creation consistent.
alter table public.project_files add column if not exists created_at timestamptz;
update public.project_files
set created_at = coalesce(created_at, uploaded_at, now())
where created_at is null;
alter table public.project_files alter column created_at set default now();
alter table public.project_files alter column created_at set not null;
create index if not exists project_files_created_at_idx on public.project_files(created_at desc);

create or replace function public.log_project_file_uploaded()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.project_activities(project_id, actor_id, action_type, description, metadata)
  values (
    new.project_id,
    coalesce(new.uploaded_by, auth.uid()),
    'file_uploaded',
    format('تم رفع الملف %s', new.file_name),
    jsonb_build_object(
      'project_file_id', new.id,
      'file_name', new.file_name,
      'file_path', new.file_path,
      'category', new.category
    )
  );
  return new;
end;
$$;

drop trigger if exists log_project_file_uploaded on public.project_files;
create trigger log_project_file_uploaded
after insert on public.project_files
for each row execute function public.log_project_file_uploaded();

drop policy if exists project_files_select on public.project_files;
drop policy if exists project_files_insert on public.project_files;
drop policy if exists project_files_delete on public.project_files;

create policy project_files_select on public.project_files
for select to authenticated
using (public.has_permission('project_files_view'));

create policy project_files_insert on public.project_files
for insert to authenticated
with check (
  public.has_permission('project_files_upload')
  and project_id is not null
  and (uploaded_by = auth.uid() or public.current_app_role() = 'manager')
);

create policy project_files_delete on public.project_files
for delete to authenticated
using (public.has_permission('project_files_delete'));

drop policy if exists project_files_storage_read on storage.objects;
drop policy if exists project_files_storage_insert on storage.objects;
drop policy if exists project_files_storage_delete on storage.objects;

create policy project_files_storage_read on storage.objects
for select to authenticated
using (bucket_id = 'project-files' and public.has_permission('project_files_view'));

create policy project_files_storage_insert on storage.objects
for insert to authenticated
with check (
  bucket_id = 'project-files'
  and public.has_permission('project_files_upload')
  and name ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/'
  and exists (
    select 1 from public.projects p
    where p.id = split_part(name, '/', 1)::uuid
  )
);

create policy project_files_storage_delete on storage.objects
for delete to authenticated
using (bucket_id = 'project-files' and public.has_permission('project_files_delete'));
