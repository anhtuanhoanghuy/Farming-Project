# Host Revoke Listener Implementation

## Problem
Host không nhận được event 'share_revoked' khi guest xác nhận revoke, nên không auto-delete share.

## Solution
Added `HostShareRevokeConfirmListener` class to listen for 'share_revoked' broadcast event from trigger.

## Changes Made

### 1. Flutter App - `lib/widgets/share_revoke_detector.dart`
- Added new class `HostShareRevokeConfirmListener` 
- Subscribes to private Realtime channel: `user:<userId>:device_shares`
- Listens for event: `share_revoked` (broadcast by trigger when guest confirms)
- On event received:
  - Extracts `share_id` from payload
  - Calls `CrudApi.deleteRevokedShare(shareId)` to auto-delete
  - Invokes callback to notify parent (e.g., reload UI)

### 2. Flutter App - `lib/screens/device_list_screen.dart`
- Added import: `share_revoke_detector`
- Added field: `late final HostShareRevokeConfirmListener _hostRevokeListener`
- In `initState()`:
  - Creates listener with callback to reload invitations when share is revoked
  - Calls `.start()` to begin listening
- In `dispose()`:
  - Calls `.dispose()` to cleanup channel subscription

## Flow (Complete 2-Phase Revoke)

```
Host App                          Trigger/Database                    Guest App
─────────────────────────────────────────────────────────────────────────────────

1. User clicks revoke
   │
   └─→ revokeShare(shareId)
       │
       └─→ UPDATE status = 'revoke_waiting'
           │
           ├─→ Trigger fires
           │   │
           │   └─→ broadcast 'share_revoke_waiting'
           │       to: user:<guest_id>:device_shares
           │                                            ←─ Guest receives event
           │                                               │
           │                                               └─→ ShareRevokeListener
           │                                                   │
           │                                                   ├─ Auto-confirm:
           │                                                   │  confirmRevoke()
           │                                                   │
           │                                                   ├─ UPDATE status = 'revoked'
           │                                                   │  │
           │                                                   │  └─→ Trigger fires
           │                                                   │      │
           │                                                   │      └─→ broadcast 'share_revoked'
           │                                                   │          to: user:<owner_id>:device_shares
           │                                                   │
           │                                                   └─ Show popup
           │                                                      Guest clicks "Đóng"
           │
           ←─ Host receives 'share_revoked' event
              │
              └─→ HostShareRevokeConfirmListener
                  │
                  ├─ Auto-delete:
                  │  deleteRevokedShare()
                  │
                  ├─ DELETE from device_shares
                  │
                  └─ Callback: reload UI
                     Share disappears from host's list
```

## Status Values
- `pending` → `accepted` (normal flow)
- `pending/accepted` → `revoke_waiting` (host initiates revoke)
- `revoke_waiting` → `revoked` (guest confirms)
- `revoked` → (deleted by host)

## Realtime Topics
- Private channel per user: `user:<user_id>:device_shares`
- Events:
  - `share_revoke_waiting`: host revokes, guest receives notification
  - `share_revoked`: guest confirms, host receives confirmation

## SQL Trigger
See `two_phase_revoke_implementation.sql` - must be deployed to Supabase.

The trigger function `broadcast_share_status_change()`:
- Listens for UPDATE on `device_shares`
- Checks status transitions
- Sends `realtime.send()` with correct signature:
  ```
  realtime.send(payload, event, topic, is_private)
  ```
- Payloads include: guest_id, device_id, share_id, type, owner_id

## Testing
1. Deploy SQL to Supabase
2. Host app: Open Device List (should start HostShareRevokeConfirmListener)
3. Host app: Click revoke on a shared device
4. Guest app: Should auto-confirm and show popup
5. Host app: Share should auto-delete and disappear from list
