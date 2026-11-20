-- Limit each device to 5 active shares (pending, accepted, revoke_waiting).
-- Re-creates invite_by_share_code from supabase_device_sharing_migration.sql with the limit check.

create or replace function public.invite_by_share_code(p_device_id uuid, p_code text)
returns public.device_shares
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_owner_id uuid;
  v_guest_id uuid;
  v_recent_attempts int;
  v_active_count int;
  v_share public.device_shares%rowtype;
begin
  v_owner_id := (select auth.uid());
  if v_owner_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if not exists (select 1 from public.devices d where d.id = p_device_id and d.user_id = v_owner_id) then
    raise exception 'Only the device owner can share this device' using errcode = '42501';
  end if;

  select count(*) into v_recent_attempts
  from public.share_attempts
  where user_id = v_owner_id and attempted_at > now() - interval '1 minute';
  if v_recent_attempts >= 5 then
    raise exception 'Too many attempts, try again later' using errcode = '42901';
  end if;
  insert into public.share_attempts (user_id) values (v_owner_id);

  select user_id into v_guest_id from public.profiles where share_code = upper(p_code);
  if v_guest_id is null then
    raise exception 'Share code not found' using errcode = '22023';
  end if;

  if v_guest_id = v_owner_id then
    raise exception 'Cannot share a device with yourself' using errcode = '22023';
  end if;

  select count(*) into v_active_count
  from public.device_shares
  where device_id = p_device_id
    and status in ('pending', 'accepted', 'revoke_waiting');
  if v_active_count >= 1 then
    raise exception 'Share limit reached' using errcode = '54000';
  end if;

  select * into v_share from public.device_shares
  where device_id = p_device_id and guest_id = v_guest_id;

  if found then
    if v_share.status = 'accepted' then
      raise exception 'This device is already shared with that account' using errcode = '23505';
    elsif v_share.status = 'pending' then
      raise exception 'An invitation is already pending for that account' using errcode = '23505';
    else
      update public.device_shares
        set status = 'pending'
        where id = v_share.id
        returning * into v_share;
    end if;
  else
    insert into public.device_shares (device_id, owner_id, guest_id, status)
    values (p_device_id, v_owner_id, v_guest_id, 'pending')
    returning * into v_share;
  end if;

  return v_share;
end;
$$;
