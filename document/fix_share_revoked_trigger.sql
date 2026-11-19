-- Step 1: Update constraint to allow 'revoked' status
-- The existing constraint is inline, so we need to drop and recreate it
alter table public.device_shares
  drop constraint if exists device_shares_status_check;

alter table public.device_shares
  add constraint device_shares_status_check
  check (status in ('pending', 'accepted', 'declined', 'revoked'));

-- Step 2: Broadcast share_revoked event to guest via Supabase Realtime
-- When share status changes to 'revoked', notify guest
-- Correct signature: realtime.send(payload, event, topic, is_private)
create or replace function public.broadcast_share_revoked()
returns trigger as $$
begin
  if TG_OP = 'UPDATE' and new.status = 'revoked' and old.status IS DISTINCT FROM 'revoked' then
    -- Send event to guest via private Realtime channel
    perform realtime.send(
      json_build_object(
        'guest_id', new.guest_id,
        'device_id', new.device_id,
        'share_id', new.id,
        'type', 'revoked'
      )::jsonb,
      'share_revoked',
      'user:' || new.guest_id::text || ':device_shares',
      true  -- is_private: only guest can receive
    );
  end if;
  return new;
end;
$$ language plpgsql;

-- Step 3: Create trigger
drop trigger if exists broadcast_share_revoked_trigger on public.device_shares;
create trigger broadcast_share_revoked_trigger
  after update on public.device_shares
  for each row
  execute function public.broadcast_share_revoked();
