-- =============================================================================
-- Device sharing: fixed share code + invite/accept flow
-- Run once in the Supabase SQL Editor. Safe to re-run (uses IF NOT EXISTS /
-- OR REPLACE / DROP POLICY IF EXISTS where possible).
--
-- Scope: public.devices, public.profiles (new), public.device_shares (new),
-- public.share_attempts (new). Does not touch loads/load_timers (they do not
-- exist). Does not change existing policies on devices/app_admins/
-- device_transfer_notices; only adds one new SELECT policy on devices.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. profiles: one row per auth user, holds the fixed share code
-- -----------------------------------------------------------------------------
create table if not exists public.profiles (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  email        text,
  display_name text,
  share_code   text not null unique,
  created_at   timestamptz not null default now()
);

alter table public.profiles enable row level security;

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own
  on public.profiles for select
  to authenticated
  using ((select auth.uid()) = user_id);

-- No insert/update/delete policies for authenticated: profiles are only
-- written by SECURITY DEFINER functions/triggers below.

-- Alphabet excludes 0/O/1/I/L to avoid ambiguous characters.
create or replace function public.generate_share_code()
returns text
language plpgsql
set search_path to ''
as $$
declare
  alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  code text;
  i int;
begin
  loop
    code := '';
    for i in 1..8 loop
      code := code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.profiles where share_code = code);
  end loop;
  return code;
end;
$$;

create or replace function public.handle_new_user_profile()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  insert into public.profiles (user_id, email, display_name, share_code)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'),
    public.generate_share_code()
  )
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile
  after insert on auth.users
  for each row execute function public.handle_new_user_profile();

-- Only the trigger (running as the function owner) should invoke this; block
-- direct calls from client roles.
revoke execute on function public.handle_new_user_profile() from public, anon, authenticated;

-- Backfill existing accounts that signed up before this migration.
insert into public.profiles (user_id, email, display_name, share_code)
select u.id, u.email, coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name'),
       public.generate_share_code()
from auth.users u
where not exists (select 1 from public.profiles p where p.user_id = u.id);

-- -----------------------------------------------------------------------------
-- 2. device_shares: invite/accept state between a device owner and a guest
-- -----------------------------------------------------------------------------
create table if not exists public.device_shares (
  id         uuid primary key default gen_random_uuid(),
  device_id  uuid not null references public.devices(id) on delete cascade,
  owner_id   uuid not null references auth.users(id) on delete cascade,
  guest_id   uuid not null references auth.users(id) on delete cascade,
  status     text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (device_id, guest_id),
  check (owner_id <> guest_id)
);

create index if not exists device_shares_guest_idx on public.device_shares (guest_id, status);
create index if not exists device_shares_owner_idx on public.device_shares (owner_id, device_id);

-- Realtime: owner sees accept/decline live, guest sees new invitations live.
do $$
begin
  alter publication supabase_realtime add table public.device_shares;
exception when duplicate_object then null;
end $$;

alter table public.device_shares enable row level security;

drop policy if exists device_shares_select_owner on public.device_shares;
create policy device_shares_select_owner
  on public.device_shares for select
  to authenticated
  using ((select auth.uid()) = owner_id);

drop policy if exists device_shares_select_guest on public.device_shares;
create policy device_shares_select_guest
  on public.device_shares for select
  to authenticated
  using ((select auth.uid()) = guest_id);

-- No direct insert/update/delete policies: all writes go through the
-- SECURITY DEFINER functions below, which validate ownership/invitee.

create or replace function public.set_device_shares_updated_at()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists device_shares_set_updated_at on public.device_shares;
create trigger device_shares_set_updated_at
  before update on public.device_shares
  for each row execute function public.set_device_shares_updated_at();

-- -----------------------------------------------------------------------------
-- 3. share_attempts: rate-limit invite-by-code guesses
-- -----------------------------------------------------------------------------
create table if not exists public.share_attempts (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  attempted_at timestamptz not null default now()
);

create index if not exists share_attempts_user_time_idx on public.share_attempts (user_id, attempted_at desc);

alter table public.share_attempts enable row level security;
-- No policies: only SECURITY DEFINER functions touch this table.

-- -----------------------------------------------------------------------------
-- 4. devices: allow accepted guests to read the device they were shared
-- -----------------------------------------------------------------------------
drop policy if exists devices_select_shared_guest on public.devices;
create policy devices_select_shared_guest
  on public.devices for select
  to authenticated
  using (
    exists (
      select 1 from public.device_shares s
      where s.device_id = devices.id
        and s.guest_id = (select auth.uid())
        and s.status = 'accepted'
    )
  );

-- Owner/admin SELECT/UPDATE/DELETE policies and guard_admin_device_update
-- trigger are unchanged. Guests get no UPDATE/DELETE policy on devices, so
-- they cannot rename or delete the device or claim it via other RPCs.

-- -----------------------------------------------------------------------------
-- 5. claim_device: drop stale shares when a device changes owner
-- -----------------------------------------------------------------------------
create or replace function public.claim_device(p_mac_address text, p_name text, p_max_sensor_count integer, p_max_load_count integer, p_device_type text DEFAULT 'controller'::text, p_power_source text DEFAULT 'mains'::text)
 RETURNS devices
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid;
  v_old_user_id uuid;
  v_device public.devices%ROWTYPE;
BEGIN
  v_user_id := (SELECT auth.uid());

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  IF p_mac_address IS NULL
     OR p_mac_address !~ '^[0-9a-f]{12}$' THEN
    RAISE EXCEPTION 'Invalid MAC address; expected 12 lowercase hexadecimal characters'
      USING ERRCODE = '22023';
  END IF;

  IF p_name IS NULL
     OR char_length(btrim(p_name)) = 0
     OR char_length(btrim(p_name)) > 64 THEN
    RAISE EXCEPTION 'Name must contain 1–64 characters after trimming'
      USING ERRCODE = '22023';
  END IF;

  IF p_max_sensor_count IS NULL OR p_max_sensor_count < 0 THEN
    RAISE EXCEPTION 'max_sensor_count must be >= 0'
      USING ERRCODE = '22023';
  END IF;

  IF p_max_load_count IS NULL OR p_max_load_count < 0 THEN
    RAISE EXCEPTION 'max_load_count must be >= 0'
      USING ERRCODE = '22023';
  END IF;

  IF p_device_type IS NULL
     OR p_device_type NOT IN ('controller', 'sensor_node') THEN
    RAISE EXCEPTION 'device_type must be controller or sensor_node'
      USING ERRCODE = '22023';
  END IF;

  IF p_power_source IS NULL
     OR p_power_source NOT IN ('mains', 'battery', 'solar_battery') THEN
    RAISE EXCEPTION 'power_source must be mains, battery or solar_battery'
      USING ERRCODE = '22023';
  END IF;

  -- Serial hóa claims cùng MAC để old_user_id, audit và notice nhất quán.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_mac_address, 0));

  SELECT d.user_id
  INTO v_old_user_id
  FROM public.devices AS d
  WHERE d.mac_address = p_mac_address
  FOR UPDATE;

  INSERT INTO public.devices AS d (
    user_id,
    mac_address,
    name,
    max_sensor_count,
    max_load_count,
    device_type,
    power_source
  )
  VALUES (
    v_user_id,
    p_mac_address,
    btrim(p_name),
    p_max_sensor_count,
    p_max_load_count,
    p_device_type,
    p_power_source
  )
  ON CONFLICT (mac_address) DO UPDATE
  SET user_id = EXCLUDED.user_id,
      name = EXCLUDED.name,
      max_sensor_count = EXCLUDED.max_sensor_count,
      max_load_count = EXCLUDED.max_load_count,
      device_type = EXCLUDED.device_type,
      power_source = EXCLUDED.power_source
  RETURNING d.* INTO v_device;

  IF v_old_user_id IS DISTINCT FROM v_user_id THEN
    INSERT INTO public.device_ownership_log (
      mac_address,
      old_user_id,
      new_user_id
    )
    VALUES (
      p_mac_address,
      v_old_user_id,
      v_user_id
    );

    -- Ownership changed: any existing shares belonged to the previous owner.
    DELETE FROM public.device_shares WHERE device_id = v_device.id;

    -- Claim lần đầu không có chủ cũ để gửi notice.
    IF v_old_user_id IS NOT NULL THEN
      INSERT INTO public.device_transfer_notices (
        user_id,
        mac_address
      )
      VALUES (
        v_old_user_id,
        p_mac_address
      );
    END IF;
  END IF;

  RETURN v_device;
END
$function$;

-- -----------------------------------------------------------------------------
-- 6. RPC functions
-- -----------------------------------------------------------------------------

-- Owner invites a guest by their fixed share code.
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

-- Guest accepts or declines a pending invitation.
create or replace function public.respond_share(p_share_id uuid, p_accept boolean)
returns public.device_shares
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

  select * into v_share from public.device_shares
  where id = p_share_id and guest_id = v_guest_id;
  if not found then
    raise exception 'Invitation not found' using errcode = '22023';
  end if;

  if v_share.status <> 'pending' then
    raise exception 'This invitation has already been answered' using errcode = '22023';
  end if;

  update public.device_shares
    set status = case when p_accept then 'accepted' else 'declined' end
    where id = p_share_id
    returning * into v_share;

  return v_share;
end;
$$;

-- Owner revokes a guest's access, or a guest removes themself.
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

  -- Update status to 'revoke_waiting' and wait for guest to confirm
  update public.device_shares set status = 'revoke_waiting' where id = p_share_id;
end;
$$;

-- Owner lists everyone a device is shared with.
create or replace function public.list_device_shares(p_device_id uuid)
returns table (
  share_id uuid,
  guest_id uuid,
  guest_email text,
  guest_display_name text,
  status text,
  created_at timestamptz
)
language sql
security definer
set search_path to 'public'
as $$
  select s.id, s.guest_id, p.email, p.display_name, s.status, s.created_at
  from public.device_shares s
  join public.profiles p on p.user_id = s.guest_id
  where s.device_id = p_device_id
    and s.owner_id = (select auth.uid());
$$;

-- Guest lists invitations sent to them.
create or replace function public.list_my_invitations()
returns table (
  share_id uuid,
  device_id uuid,
  device_name text,
  owner_id uuid,
  owner_email text,
  status text,
  created_at timestamptz
)
language sql
security definer
set search_path to 'public'
as $$
  select s.id, s.device_id, d.name, s.owner_id, p.email, s.status, s.created_at
  from public.device_shares s
  join public.devices d on d.id = s.device_id
  join public.profiles p on p.user_id = s.owner_id
  where s.guest_id = (select auth.uid());
$$;

-- Caller regenerates their own share code.
create or replace function public.regenerate_share_code()
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_user_id uuid;
  v_code text;
begin
  v_user_id := (select auth.uid());
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  v_code := public.generate_share_code();
  update public.profiles set share_code = v_code where user_id = v_user_id;
  return v_code;
end;
$$;

-- Looks up the account behind a share code, without creating an invitation.
-- Used by the share dialog to show the owner the full account before they
-- send the invite ("Tài khoản: ..." or "Không tìm thấy người này").
create or replace function public.lookup_share_code(p_code text)
returns table (guest_user_id uuid, email text, display_name text)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_caller uuid;
begin
  v_caller := (select auth.uid());
  if v_caller is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  return query
    select p.user_id, p.email, p.display_name
    from public.profiles p
    where p.share_code = upper(p_code);
end;
$$;

-- Lets a guest remove themself from a shared device without knowing their
-- own share_id.
create or replace function public.leave_shared_device(p_device_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_caller uuid;
begin
  v_caller := (select auth.uid());
  if v_caller is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  delete from public.device_shares
  where device_id = p_device_id and guest_id = v_caller;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Grants
-- -----------------------------------------------------------------------------
revoke all on function public.invite_by_share_code(uuid, text) from public, anon;
revoke all on function public.respond_share(uuid, boolean) from public, anon;
revoke all on function public.revoke_share(uuid) from public, anon;
revoke all on function public.list_device_shares(uuid) from public, anon;
revoke all on function public.list_my_invitations() from public, anon;
revoke all on function public.regenerate_share_code() from public, anon;
revoke all on function public.lookup_share_code(text) from public, anon;
revoke all on function public.leave_shared_device(uuid) from public, anon;

grant execute on function public.invite_by_share_code(uuid, text) to authenticated;
grant execute on function public.respond_share(uuid, boolean) to authenticated;
grant execute on function public.revoke_share(uuid) to authenticated;
grant execute on function public.list_device_shares(uuid) to authenticated;
grant execute on function public.list_my_invitations() to authenticated;
grant execute on function public.regenerate_share_code() to authenticated;
grant execute on function public.lookup_share_code(text) to authenticated;
grant execute on function public.leave_shared_device(uuid) to authenticated;

grant select on public.profiles to authenticated;
grant select on public.device_shares to authenticated;

-- -----------------------------------------------------------------------------
-- 8. Realtime: let clients see invite/accept/revoke changes live
-- Guarded so re-running this script after the table is already published does
-- not error.
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'device_shares'
  ) then
    alter publication supabase_realtime add table public.device_shares;
  end if;
end;
$$;
