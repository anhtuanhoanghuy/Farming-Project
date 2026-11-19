-- Broadcast share_removed event to guest when share is deleted
-- Run this in Supabase SQL Editor

create or replace function public.broadcast_share_removed()
returns trigger as $$
begin
  if TG_OP = 'DELETE' then
    -- Use short channel name to stay under 63 char limit
    perform pg_notify(
      'share_removed',
      json_build_object(
        'guest_id', old.guest_id,
        'device_id', old.device_id,
        'share_id', old.id
      )::text
    );
  end if;
  return old;
end;
$$ language plpgsql;

drop trigger if exists device_shares_broadcast_removed on public.device_shares;
create trigger device_shares_broadcast_removed
  after delete on public.device_shares
  for each row execute function public.broadcast_share_removed();
