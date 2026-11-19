-- Two-phase revoke flow: host waits for guest confirmation before deleting
-- Status flow: accepted/pending → revoke_waiting → revoked → (host deletes)

-- Step 1: Update constraint to allow 'revoke_waiting' and 'revoked'
alter table public.device_shares
  drop constraint if exists device_shares_status_check;

alter table public.device_shares
  add constraint device_shares_status_check
  check (status in ('pending', 'accepted', 'declined', 'revoke_waiting', 'revoked'));

-- Step 2: Broadcast event whenever status changes (revoke_waiting or revoked)
create or replace function public.broadcast_share_status_change()
returns trigger as $$
begin
  if TG_OP = 'UPDATE' then
    -- Broadcast to guest when host revokes (status = 'revoke_waiting')
    if new.status = 'revoke_waiting' and old.status IS DISTINCT FROM 'revoke_waiting' then
      perform realtime.send(
        json_build_object(
          'guest_id', new.guest_id,
          'device_id', new.device_id,
          'share_id', new.id,
          'type', 'revoke_waiting',
          'owner_id', new.owner_id
        )::jsonb,
        'share_revoke_waiting',
        'user:' || new.guest_id::text || ':device_shares',
        true
      );
    end if;
    
    -- Broadcast to host when guest confirms revoke (status = 'revoked')
    if new.status = 'revoked' and old.status = 'revoke_waiting' then
      perform realtime.send(
        json_build_object(
          'guest_id', new.guest_id,
          'device_id', new.device_id,
          'share_id', new.id,
          'type', 'revoked',
          'owner_id', new.owner_id
        )::jsonb,
        'share_revoked',
        'user:' || new.owner_id::text || ':device_shares',
        true
      );
    end if;
  end if;
  return new;
end;
$$ language plpgsql;

-- Step 3: Create trigger
drop trigger if exists broadcast_share_status_change_trigger on public.device_shares;
create trigger broadcast_share_status_change_trigger
  after update on public.device_shares
  for each row
  execute function public.broadcast_share_status_change();

-- Step 4: Modify revoke_share RPC to update status to 'revoke_waiting' instead of deleting
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
     and v_caller <> v_share.guest_id
     and not exists (select 1 from public.app_admins a where a.user_id = v_caller) then
    raise exception 'Not authorized to revoke this share' using errcode = '42501';
  end if;

  -- Update status directly to 'revoked' - no waiting phase
  update public.device_shares set status = 'revoked' where id = p_share_id;
end;
$$;

-- Step 5: New RPC for guest to confirm they received revoke notification
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

  -- Only guest can confirm revoke
  if v_guest_id <> v_share.guest_id then
    raise exception 'Only guest can confirm revoke' using errcode = '42501';
  end if;

  -- Can only confirm from 'revoke_waiting' status
  if v_share.status <> 'revoke_waiting' then
    raise exception 'Share is not waiting for revoke confirmation' using errcode = '22023';
  end if;

  -- Update status to 'revoked' (confirmed)
  update public.device_shares set status = 'revoked' where id = p_share_id;
end;
$$;

-- Step 6: RPC for host to delete share after guest confirmed revoke
-- (can be called after receiving 'revoked' event)
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

  -- Only owner can delete
  if v_caller <> v_share.owner_id
     and not exists (select 1 from public.app_admins a where a.user_id = v_caller) then
    raise exception 'Not authorized to delete this share' using errcode = '42501';
  end if;

  -- Can only delete if revoked (confirmed by guest) or declined
  if v_share.status <> 'revoked' and v_share.status <> 'declined' then
    raise exception 'Can only delete revoked or declined shares' using errcode = '22023';
  end if;

  delete from public.device_shares where id = p_share_id;
end;
$$;

-- Step 7: Grant permissions
revoke all on function public.revoke_share(uuid) from public, anon;
revoke all on function public.confirm_revoke(uuid) from public, anon;
revoke all on function public.delete_revoked_share(uuid) from public, anon;

grant execute on function public.revoke_share(uuid) to authenticated;
grant execute on function public.confirm_revoke(uuid) to authenticated;
grant execute on function public.delete_revoked_share(uuid) to authenticated;
