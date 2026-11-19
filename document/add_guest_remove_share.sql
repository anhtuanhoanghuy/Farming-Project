-- Add missing guest_remove_share function to allow guests to self-remove from shared devices
-- Database already has: revoke_share, confirm_revoke, delete_revoked_share
-- Database already has: device_shares in supabase_realtime publication ✓

-- Step 1: Ensure constraint allows all statuses (pending, accepted, declined, revoke_waiting, revoked)
alter table public.device_shares
  drop constraint if exists device_shares_status_check;

alter table public.device_shares
  add constraint device_shares_status_check
  check (status in ('pending', 'accepted', 'declined', 'revoke_waiting', 'revoked'));

-- Step 2: Add guest_remove_share - guest can self-remove from accepted shares
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

-- Step 3: Grant permissions
revoke all on function public.guest_remove_share(uuid) from public, anon;
grant execute on function public.guest_remove_share(uuid) to authenticated;
