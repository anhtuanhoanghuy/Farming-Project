-- Ensure device_shares table is in the realtime publication
-- This allows Supabase Realtime to broadcast changes to subscribed clients

-- First, check if table is already in publication
-- SELECT schemaname, tablename FROM pg_publication_tables 
-- WHERE pubname = 'supabase_realtime' AND tablename = 'device_shares';

-- Add device_shares to supabase_realtime publication if not already there
ALTER PUBLICATION supabase_realtime ADD TABLE public.device_shares;
