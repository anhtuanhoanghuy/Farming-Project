-- Clean 2-phase revoke flow using Supabase Realtime streams (no triggers needed)
-- Status flow: accepted/pending → revoke_waiting → revoked → (host deletes)

-- Step 1: Ensure constraint allows 'revoke_waiting' and 'revoked' states
alter table public.device_shares
  drop constraint if exists device_shares_status_check;

alter table public.device_shares
  add constraint device_shares_status_check
  check (status in ('pending', 'accepted', 'declined', 'revoke_waiting', 'revoked'));

-- Step 2: Host revokes access (sets status to 'revoke_waiting')
create or replace function public.revoke_share(p_share_id uuid)
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
    raise exception 'Not authorized to revoke this share' using errcode = '42501';
  end if;

  -- Set status to 'revoke_waiting' - guest stream will detect this
  update public.device_shares set status = 'revoke_waiting' where id = p_share_id;
end;
$$;

-- Step 3: Guest confirms they received revoke notification
create or replace function public.confirm_revoke(p_share_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_guest_id uuid;
  v_share public.device_shares%rowtype;
begin
  v_guest_id := (select auth.uid());
  if v_guest_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select * into v_share from public.device_shares where id = p_share_id;
  if not found then
    raise exception 'Share not found' using errcode = '22023';
  end if;

  if v_guest_id <> v_share.guest_id then
    raise exception 'Only guest can confirm revoke' using errcode = '42501';
  end if;

  if v_share.status <> 'revoke_waiting' then
    raise exception 'Share is not waiting for revoke confirmation' using errcode = '22023';
  end if;

  -- Update status to 'revoked' - host stream will detect this
  update public.device_shares set status = 'revoked' where id = p_share_id;
end;
$$;

-- Step 4: Host deletes a revoked or declined share
create or replace function public.delete_revoked_share(p_share_id uuid)
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

  if v_share.status <> 'revoked' and v_share.status <> 'declined' then
    raise exception 'Can only delete revoked or declined shares' using errcode = '22023';
  end if;

  delete from public.device_shares where id = p_share_id;
end;
$$;

-- Step 5: Guest can self-remove (voluntary leave)
create or replace function public.guest_remove_share(p_share_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_guest_id uuid;
  v_share public.device_shares%rowtype;
begin
  v_guest_id := (select auth.uid());
  if v_guest_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select * into v_share from public.device_shares where id = p_share_id;
  if not found then
    return;
  end if;

  if v_guest_id <> v_share.guest_id then
    raise exception 'Only guest can self-remove' using errcode = '42501';
  end if;

  -- Can only remove accepted shares
  if v_share.status <> 'accepted' then
    raise exception 'Can only remove accepted shares' using errcode = '22023';
  end if;

  -- Guest directly deletes the share
  delete from public.device_shares where id = p_share_id;
end;
$$;

-- Step 6: Grant permissions
revoke all on function public.revoke_share(uuid) from public, anon;
revoke all on function public.confirm_revoke(uuid) from public, anon;
revoke all on function public.delete_revoked_share(uuid) from public, anon;
revoke all on function public.guest_remove_share(uuid) from public, anon;

grant execute on function public.revoke_share(uuid) to authenticated;
grant execute on function public.confirm_revoke(uuid) to authenticated;
grant execute on function public.delete_revoked_share(uuid) to authenticated;
grant execute on function public.guest_remove_share(uuid) to authenticated;

-- Step 7: Ensure device_shares is in realtime publication
alter publication supabase_realtime add table if not exists public.device_shares;
