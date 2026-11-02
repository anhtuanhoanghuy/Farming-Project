## Table `devices`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `user_id` | `uuid` |  |
| `mac_address` | `text` |  Unique |
| `name` | `text` |  |
| `max_sensor_count` | `int4` | Required · from BLE provisioning result |
| `max_load_count` | `int4` | Required · from BLE provisioning result |
| `created_at` | `timestamptz` |  |

## Ownership transfer

A device has exactly one owner. After BLE provisioning with the new account's
`user_id`, the app calls the RPC `claim_device(p_mac_address, p_name,
p_max_sensor_count, p_max_load_count)`; if the MAC already belongs to another
account, the owner changes to `auth.uid()`. The server then inserts a row in
`device_transfer_notices` (`id`, `user_id` = previous owner, `mac_address`,
`created_at`) for the previous owner. The app of the previous owner streams its
notices, removes the device locally (list, MQTT subscription, health log),
shows "Thiết bị … hiện không còn thuộc tài khoản này" and deletes the notice.

The normal ownership policies allow `devices` to be read, renamed and deleted
by its owner only. Admin exceptions are described below; the app never inserts
into it directly.

## Admin access

The app also supports `public.app_admins(user_id uuid primary key references
auth.users(id))`. RLS must allow a signed-in user to read their own membership,
but not grant membership from the client. Admin policies on `devices` must
allow reading every owner's devices and updating names, according to the
applied server migration. The existing ownership/claim flow is unchanged.

With developer mode enabled, tap the MQTT connection strip above the bottom
navigation bar exactly 10 times to verify membership and enable admin mode.
No time limit is applied to the taps. Until verification succeeds, the app
queries only the signed-in user's devices. Admin mode is session-only; use
the strip's close button, disable developer access, or sign out to leave it.
Signing out or switching accounts also disables the persisted developer mode.
After signing in again, enable developer mode again before starting a fresh
10-tap sequence. Revoking developer access also resets any partial sequence.

In admin mode the app reads all pages of devices, uses each row's `user_id`
for MQTT subscriptions and commands, and never claims the device or changes
its owner. All-device lists and foreign MQTT device registrations are not
persisted. Leaving the mode disconnects the session and reloads only owned
devices, clearing foreign health logs and the session traffic log.

Supabase authorization does not authorize MQTT. The current anonymous broker
must separately permit these topics; hidden taps only gate the app UI and do
not prevent other MQTT clients from accessing an unrestricted broker.

Known limit: any signed-in user who knows a MAC can call `claim_device`. A
one-time claim token issued by the ESP32 (or checked by the backend) is needed
to prove the caller was really provisioning the device.

## RLS Policies

Replaced by the ownership migration: owner-only SELECT/UPDATE/DELETE on
`devices`, no direct INSERT, and owner-only SELECT/DELETE on
`device_transfer_notices`. Before it, `devices` had:

### `devices`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `devices_owner_all` | ALL | authenticated | PERMISSIVE | `(user_id = ( SELECT auth.uid() AS uid))` | `(user_id = ( SELECT auth.uid() AS uid))` |
