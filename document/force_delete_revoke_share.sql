-- Host force-deletes a share that is still 'revoke_waiting' (guest did not
-- confirm in time) or already 'revoked'. Used by the app 10 seconds after a revoke.

create or replace function public.force_delete_revoke_share(p_share_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_caller uuid;
  v_share public.device_shares%rowtype;
begin
  v_caller := (select auth.uid());
  if v_caller is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select * into v_share from public.device_shares where id = p_share_id;
  if not found then
    return;
  end if;

  if v_caller <> v_share.owner_id
     and not exists (select 1 from public.app_admins a where a.user_id = v_caller) then
    raise exception 'Not authorized to delete this share' using errcode = '42501';
  end if;

  if v_share.status not in ('revoke_waiting', 'revoked') then
    return;
  end if;

  delete from public.device_shares where id = p_share_id;
end;
$$;

revoke all on function public.force_delete_revoke_share(uuid) from public, anon;
grant execute on function public.force_delete_revoke_share(uuid) to authenticated;
