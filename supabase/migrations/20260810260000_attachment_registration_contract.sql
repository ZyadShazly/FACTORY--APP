-- Register uploaded project and asset files through audited, permission-aware commands.
begin;

create unique index if not exists asset_attachments_bucket_path_uidx
  on public.asset_attachments(bucket_name,file_path);

create or replace function public.register_project_file_upload(
  target_project uuid, file_path text, file_name text, file_type text,
  file_size bigint, file_category text default 'other', file_description text default null
) returns public.project_files
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); saved public.project_files%rowtype;
begin
  if actor is null or not public.is_current_profile_active()
     or not private.project_can_view(target_project)
     or not private.project_has_permission('project_files_upload') then
    raise exception using errcode='42501',message='Project file upload permission required';
  end if;
  if nullif(btrim(file_name),'') is null or file_size is null or file_size<0 or file_size>52428800 then
    raise exception using errcode='22023',message='Invalid project file metadata';
  end if;
  if file_category not in ('2d','3d','measurements','cutting_list','approvals','site_photos','other') then
    raise exception using errcode='22023',message='Invalid project file category';
  end if;
  if file_path is null or file_path not like target_project::text||'/%'
     or not exists(select 1 from storage.objects where bucket_id='project-files' and name=file_path) then
    raise exception using errcode='23503',message='Uploaded project object not found';
  end if;
  select * into saved from public.project_files where project_files.file_path=register_project_file_upload.file_path;
  if found then
    if saved.project_id<>target_project or saved.uploaded_by<>actor then raise exception using errcode='23505',message='File path is already registered'; end if;
    return saved;
  end if;
  insert into public.project_files(project_id,file_name,file_path,file_type,file_size,category,description,uploaded_by)
  values(target_project,btrim(file_name),file_path,nullif(btrim(file_type),''),file_size,file_category,nullif(btrim(file_description),''),actor)
  returning * into saved;
  return saved;
end $$;

create or replace function public.register_asset_attachment(
  target_asset uuid, file_path text, file_name text, file_type text, file_size bigint
) returns public.asset_attachments
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); saved public.asset_attachments%rowtype;
begin
  if actor is null or not public.is_current_profile_active() or not public.has_permission('assets_manage') then
    raise exception using errcode='42501',message='Asset attachment permission required';
  end if;
  if not exists(select 1 from public.assets where id=target_asset) then raise exception using errcode='23503',message='Asset not found'; end if;
  if nullif(btrim(file_name),'') is null or file_size is null or file_size<0 or file_size>52428800 then
    raise exception using errcode='22023',message='Invalid asset attachment metadata';
  end if;
  if file_path is null or file_path not like target_asset::text||'/%'
     or not exists(select 1 from storage.objects where bucket_id='asset-attachments' and name=file_path) then
    raise exception using errcode='23503',message='Uploaded asset object not found';
  end if;
  select * into saved from public.asset_attachments where bucket_name='asset-attachments' and asset_attachments.file_path=register_asset_attachment.file_path;
  if found then
    if saved.asset_id<>target_asset or saved.uploaded_by<>actor then raise exception using errcode='23505',message='Attachment path is already registered'; end if;
    return saved;
  end if;
  insert into public.asset_attachments(asset_id,file_name,file_path,file_type,file_size,bucket_name,uploaded_by)
  values(target_asset,btrim(file_name),file_path,nullif(btrim(file_type),''),file_size,'asset-attachments',actor)
  returning * into saved;
  return saved;
end $$;

create or replace function public.discard_unregistered_upload(bucket_name text,file_path text)
returns boolean language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); target_id uuid;
begin
  if actor is null or not public.is_current_profile_active() then raise exception using errcode='42501',message='Authentication required'; end if;
  begin target_id:=split_part(file_path,'/',1)::uuid; exception when others then raise exception using errcode='22023',message='Invalid upload path'; end;
  if bucket_name='project-files' then
    if not private.project_can_view(target_id) or not private.project_has_permission('project_files_upload') then raise exception using errcode='42501',message='Project file upload permission required'; end if;
    if exists(select 1 from public.project_files where project_files.file_path=discard_unregistered_upload.file_path) then return false; end if;
  elsif bucket_name='asset-attachments' then
    if not public.has_permission('assets_manage') or not exists(select 1 from public.assets where id=target_id) then raise exception using errcode='42501',message='Asset attachment permission required'; end if;
    if exists(select 1 from public.asset_attachments where asset_attachments.bucket_name=discard_unregistered_upload.bucket_name and asset_attachments.file_path=discard_unregistered_upload.file_path) then return false; end if;
  else
    raise exception using errcode='22023',message='Unsupported upload bucket';
  end if;
  delete from storage.objects where bucket_id=bucket_name and name=file_path;
  return found;
end $$;

revoke all on function public.register_project_file_upload(uuid,text,text,text,bigint,text,text),
  public.register_asset_attachment(uuid,text,text,text,bigint),public.discard_unregistered_upload(text,text)
  from public,anon,authenticated;
grant execute on function public.register_project_file_upload(uuid,text,text,text,bigint,text,text),
  public.register_asset_attachment(uuid,text,text,text,bigint),public.discard_unregistered_upload(text,text)
  to authenticated;

revoke insert on table public.project_files,public.asset_attachments from anon,authenticated;

commit;
