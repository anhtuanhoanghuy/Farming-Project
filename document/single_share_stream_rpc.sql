-- RPC to get all shares where user is guest OR owner
-- This allows a single stream subscription instead of two separate streams

create or replace function public.get_my_shares()
returns table (
  id uuid,
  owner_id uuid,
  guest_id uuid,
  device_id uuid,
  status text,
  created_at timestamp with time zone,
  updated_at timestamp with time zone
) as $$
begin
  return query
    select 
      ds.id,
      ds.owner_id,
      ds.guest_id,
      ds.device_id,
      ds.status,
      ds.created_at,
      ds.updated_at
    from public.device_shares ds
    where ds.guest_id = auth.uid() or ds.owner_id = auth.uid()
    order by ds.updated_at desc;
end;
$$ language plpgsql
security definer
set search_path to 'public';

-- Grant permission to authenticated users
grant execute on function public.get_my_shares() to authenticated;

-- Add to realtime publication so changes are broadcast
alter publication supabase_realtime add table public.device_shares;
