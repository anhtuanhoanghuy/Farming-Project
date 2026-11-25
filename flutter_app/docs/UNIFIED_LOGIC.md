# Device Access Control - Unified Logic Diagram

## Overview

```
All 3 cases use SAME mechanism:
┌─────────────────────────────────────────────────┐
│ Stream Change (device_shares or devices table) │
└──────────────────┬──────────────────────────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │ _checkAccess()       │
        │                      │
        │ Compare:             │
        │ • Current (cached)   │
        │ • Accessible (fresh) │
        └──────────────────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │ Lost devices?        │
        └──────────────────────┘
                   │
         ┌─────────┴──────────┐
         │                    │
         ▼ YES                ▼ NO
    revoked.add()         (do nothing)
         │
         ▼
   ShareRevokeListener
         │
         ├─ Show SnackBar
         └─ popUntil()
```

## Case-by-Case Logic

### Case 1: Share Revoke

```
Backend Change:
  DELETE FROM device_shares WHERE id = share_id

Supabase Event:
  device_shares stream → event fires

DeviceAccessWatcher._startShareListener():
  _checkAccess() called

_checkAccess():
  currentDevices = [Device A, Device B] ← cached
  
  ownedDevices = [Device A]  ← fresh from listDevices()
  sharedDevices = []         ← fresh from listSharedDevices() (Device B removed!)
  
  accessible = { A_uuid }
  
  Check Device A: A_uuid in accessible → ✓ keep
  Check Device B: B_uuid NOT in accessible → ✗ LOST!
  
  revoked.add(B_macAddress)

Guest's Dashboard (Device B):
  ShareRevokeListener.listen(revoked)
  Receives: B_macAddress
  Match: device.deviceId == B_macAddress → ✓
  _onRevoked()
  ├─ Show: "Quyền truy cập thiết bị đã bị thu hồi"
  └─ popUntil()

Result:
  ✅ Guest sees SnackBar + auto-pops from Dashboard
  ✅ Device B removed from guest's device list (after refresh)
```

### Case 2: Ownership Transfer (Owner + Guest)

```
Backend Change:
  UPDATE devices SET user_id = new_user_id WHERE id = device_id

Supabase Event:
  devices stream → event fires (for BOTH old and new owner)

Old Owner's DeviceAccessWatcher._startDeviceListener():
  _checkAccess() called

_checkAccess():
  currentDevices = [Device X] ← cached
  
  ownedDevices = []          ← fresh from listDevices() (Device X not owned anymore!)
  sharedDevices = []         ← fresh from listSharedDevices()
  
  accessible = {}
  
  Check Device X: X_uuid NOT in accessible → ✗ LOST!
  
  revoked.add(X_macAddress)

Old Owner's Dashboard:
  ShareRevokeListener.listen(revoked)
  Receives: X_macAddress
  Match: device.deviceId == X_macAddress → ✓
  _onRevoked()
  ├─ Show: "Quyền truy cập thiết bị đã bị thu hồi"
  └─ popUntil()

Result:
  ✅ Owner sees SnackBar + auto-pops from Dashboard
  ✅ Device X removed from owner's device list


Guest's DeviceAccessWatcher._startDeviceListener():
  (Also fires because devices table changed)
  _checkAccess() called

_checkAccess():
  currentDevices = [Device X] ← cached
  
  ownedDevices = []          ← fresh from listDevices() (not owned by guest)
  sharedDevices = []         ← fresh from listSharedDevices() (share is GONE!)
                                                              (why? device now owned by stranger)
  
  accessible = {}
  
  Check Device X: X_uuid NOT in accessible → ✗ LOST!
  
  revoked.add(X_macAddress)

Guest's Dashboard:
  ShareRevokeListener.listen(revoked)
  Receives: X_macAddress
  Match: device.deviceId == X_macAddress → ✓
  _onRevoked()
  ├─ Show: "Quyền truy cập thiết bị đã bị thu hồi"
  └─ popUntil()

Result:
  ✅ Guest also sees SnackBar + auto-pops from Dashboard
  ✅ Device X removed from guest's device list
  ✅ BOTH owner and guest get kicked out!
```

### Case 3: Ownership Transfer (Owner only, no guest)

```
Backend Change:
  UPDATE devices SET user_id = new_user_id WHERE id = device_id

Supabase Event:
  devices stream → event fires (for old owner)

Owner's DeviceAccessWatcher._startDeviceListener():
  _checkAccess() called

_checkAccess():
  currentDevices = [Device X] ← cached (owner had it)
  
  ownedDevices = []          ← fresh from listDevices() (not owned anymore!)
  sharedDevices = []         ← fresh from listSharedDevices() (no shares)
  
  accessible = {}
  
  Check Device X: X_uuid NOT in accessible → ✗ LOST!
  
  revoked.add(X_macAddress)

Owner's Dashboard:
  ShareRevokeListener.listen(revoked)
  Receives: X_macAddress
  Match: device.deviceId == X_macAddress → ✓
  _onRevoked()
  ├─ Show: "Quyền truy cập thiết bị đã bị thu hồi"
  └─ popUntil()

Result:
  ✅ Owner sees SnackBar + auto-pops from Dashboard
  ✅ Device X removed from owner's device list
  ✅ No guest affected (didn't have access anyway)
```

## Key Insights

### Why Unified Logic Works

| Event | Table | Listen | Check | Result |
|-------|-------|--------|-------|--------|
| Share Revoke | device_shares | ✅ shareChanges | listSharedDevices() | Guest kicked ✓ |
| Transfer (Owner) | devices | ✅ deviceChanges | listDevices() | Owner kicked ✓ |
| Transfer (Guest) | devices | ✅ deviceChanges | listSharedDevices() | Guest kicked ✓ |
| Ownership+Share | both | ✅ both streams | both lists | Both kicked ✓ |

### Why It's Safe

**Problem:** Could multiple events fire for same device?
```
Ownership transfer happens:
  devices table changes
  → Old owner's deviceChanges stream fires
  → Guest's deviceChanges stream fires
  → Guest's shareChanges stream fires (share invalid)
  → Old owner's shareChanges stream fires (might be owner role)
```

**Solution:**
- Each stream event calls same `_checkAccess()`
- Multiple calls to same function safe (idempotent)
- Each check compares fresh data
- `revoked.add()` can be called multiple times → only emit once per device
- Multiple listeners safe (broadcast stream)

**Result:** ✅ No race conditions, only one SnackBar visible anyway

## State Transitions

```
User can be in one of 3 states per device:

STATE 1: OWNER
  ├─ Access: listDevices() returns device
  ├─ Revoke trigger: ownership transfer → listDevices() doesn't return
  └─ Result: Kicked out + "Quyền truy cập thiết bị đã bị thu hồi"

STATE 2: GUEST (shared)
  ├─ Access: listSharedDevices() returns device
  ├─ Revoke trigger: 
  │   - Share deleted → listSharedDevices() doesn't return
  │   - Owner transfers → listSharedDevices() doesn't return
  └─ Result: Kicked out + "Quyền truy cập thiết bị đã bị thu hồi"

STATE 3: NO ACCESS
  ├─ Access: Device not in either list
  ├─ Revoke trigger: N/A (already no access)
  └─ Result: N/A

Transitions:
  OWNER → GUEST (share device)
  OWNER → NO ACCESS (transfer or delete)
  GUEST → NO ACCESS (revoke or owner transfers)
```

## Network Reliability

```
Scenario: Network disconnect during revoke

Timeline:
  T0: Guest has access, app online
  T1: Owner revokes share
  T2: Network disconnects
  T3: Guest still online (cached)
  T4: Guest tries to access device detail
  T5: Network reconnects
  T6: Realtime streams reconnect
  T7: Supabase sends pending events
  T8: DeviceAccessWatcher receives event
  T9: _checkAccess() detects loss
  T10: revoked.add() triggers
  T11: SnackBar + pop

Result:
  ✅ Even if offline, kicked out when reconnected
  ✅ No "stale" access possible
  ✓ Slight delay (T2-T6) but eventually consistent
```

## Performance Analysis

| Operation | Cost | When |
|-----------|------|------|
| Stream subscription | Low | App startup (once) |
| Listen to stream | Low | Per screen (unavoidable) |
| _checkAccess() | Medium | On each change (not often) |
| listDevices() | High | Per _checkAccess() |
| listSharedDevices() | High | Per _checkAccess() |
| Repository.refresh() | High | Per _checkAccess() |

**Optimization Opportunity:** Could debounce multiple stream events within 500ms to single _checkAccess() call.

**Decision:** Accept current implementation (no debounce) because:
- Share revoke/transfer infrequent events
- No significant performance impact for most apps
- Simpler code, easier to debug
- Millisecond difference negligible to user experience

## Testing Verification Matrix

| Case | Event | Stream | Check Method | Expected |
|------|-------|--------|--------------|----------|
| Share Revoke | device_shares | shareChanges | listSharedDevices | Guest out ✓ |
| Owner Transfer | devices | deviceChanges | listDevices | Owner out ✓ |
| Guest Transfer | devices | deviceChanges | listSharedDevices | Guest out ✓ |
| Both Transfer | devices | deviceChanges | both lists | Both out ✓ |
| Delete | devices | deviceChanges | both lists | All out ✓ |

✅ **All cases handled by unified mechanism**
