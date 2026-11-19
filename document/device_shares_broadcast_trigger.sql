-- Trigger to broadcast device share status changes via Realtime
-- Sends events when status changes to 'revoke_waiting' (to guest) or 'revoked' (to owner)

create or replace function public.broadcast_device_share_status_change()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  -- Broadcast 'share_revoke_waiting' to guest when status changes to 'revoke_waiting'
  if new.status = 'revoke_waiting' and (old.status <> 'revoke_waiting' or old is null) then
    perform realtime.send(
      'user:' || new.guest_id::text || ':device_shares',
      json_build_object('event', 'share_revoke_waiting', 'share_id', new.id)::text,
      true
    );
  end if;

  -- Broadcast 'share_revoked' to owner when status changes to 'revoked'
  if new.status = 'revoked' and (old.status <> 'revoked' or old is null) then
    perform realtime.send(
      'user:' || new.owner_id::text || ':device_shares',
      json_build_object('event', 'share_revoked', 'share_id', new.id)::text,
      true
    );
  end if;

  return new;
end;
$$;

-- Drop existing trigger if it exists
drop trigger if exists device_shares_broadcast_status_change on public.device_shares;

-- Create trigger
create trigger device_shares_broadcast_status_change
after update on public.device_shares
for each row
execute function public.broadcast_device_share_status_change();
