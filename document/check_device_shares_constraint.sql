-- Check current constraint on device_shares.status
select constraint_name, constraint_definition
from information_schema.table_constraints
join information_schema.check_constraints on table_constraints.constraint_name = check_constraints.constraint_name
where table_schema = 'public' and table_name = 'device_shares';

-- Or check the column directly
select column_name, column_default, is_nullable, data_type
from information_schema.columns
where table_schema = 'public' and table_name = 'device_shares' and column_name = 'status';

-- Check all rows in device_shares
select id, device_id, owner_id, guest_id, status, created_at, updated_at
from public.device_shares
order by created_at desc
limit 50;

-- Check if there are any triggers on device_shares
select trigger_name, event_manipulation, action_statement
from information_schema.triggers
where event_object_schema = 'public' and event_object_table = 'device_shares';
