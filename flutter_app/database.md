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

`devices` is read, renamed and deleted by its owner only; the app never inserts
into it directly.

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
