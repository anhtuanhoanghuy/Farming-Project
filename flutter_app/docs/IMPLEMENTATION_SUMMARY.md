# Implementation Summary: Device Access Revoke & Ownership Transfer

## Status: ✅ COMPLETED

### Problem Solved
When a device owner:
1. **Revokes share** to a guest → Guest can still view & control device
2. **Transfers ownership** to another account → Guest can still view & control device

**Expected behavior:** Guest should be auto-logged out from all device-related screens.

### Solution Architecture

```
┌─ DeviceAccessWatcher (Singleton Service) ─────────────────┐
│                                                             │
│  Listens to 2 streams:                                      │
│  1. device_shares table (share revoke)                      │
│  2. devices table (ownership transfer)                      │
│                                                             │
│  On change → Check access → Broadcast revoked event        │
│                                                             │
│  revoked: Stream<String>  // MAC addresses                  │
└─────────────────────────────────────────────────────────────┘
                              ↓
                    ShareRevokeListener
                              ↓
        ┌─────────────────────────────────────┐
        │ Attached to all device screens:     │
        │ - DashboardScreen                  │
        │ - SensorCapacityScreen             │
        │ - SensorConfigScreen               │
        │ - LoadControlScreen                │
        │ - DiagnosticsScreen                │
        └─────────────────────────────────────┘
                              ↓
                   On revoked event:
                   1. Show SnackBar
                   2. popUntil((route) => route.isFirst)
                      (Pops all device screens back to home)
```

### Implementation Details

#### 1. CrudApi Enhancement
**File:** `lib/services/crud_api.dart`
- Added `deviceChanges(String userId)` method
- Listens to realtime changes on `devices` table filtered by `user_id`
- Detects when ownership is transferred (user_id changes)

#### 2. New DeviceAccessWatcher Service
**File:** `lib/services/device_access_watcher.dart`
- Singleton pattern
- Subscribes to both `shareChanges` and `deviceChanges` streams
- Seeds first event to skip initial snapshot
- On stream events: Checks device access and broadcasts revoked MAC addresses
- Efficiency: One global broadcast instead of N individual checks

#### 3. Refactored ShareRevokeListener
**File:** `lib/widgets/share_revoke_detector.dart`
- Was: Manual checking on each stream event
- Now: Listens to global `DeviceAccessWatcher.revoked` broadcast
- Much simpler and more efficient
- Prevents duplicate work when multiple screens are open

#### 4. App Startup Initialization
**File:** `lib/screens/splash_screen.dart`
- Starts `DeviceAccessWatcher` after user signs in
- Runs continuously to detect access changes

#### 5. Bug Fix
**File:** `lib/screens/diagnostics_screen.dart`
- Changed `widget.device.id` → `widget.device.macAddress`
- Consistency: All screens now pass MAC address (deviceId) to ShareRevokeListener

### Device ID Mapping Reference

| File | Widget Type | Property | ID Type | Status |
|------|-------------|----------|---------|--------|
| dashboard_screen.dart | DeviceSelection | deviceId | MAC | ✓ |
| sensor_capacity_screen.dart | DeviceSelection | deviceId | MAC | ✓ |
| sensor_config_screen.dart | SensorConfigSelection | device.deviceId | MAC | ✓ |
| load_control_screen.dart | DeviceSelection | deviceId | MAC | ✓ |
| diagnostics_screen.dart | DeviceRecord | macAddress | MAC | ✓ |

**Critical:** All must use **MAC address** (deviceId or macAddress), not UUID (id).

### How It Works

#### Scenario A: Share Revoke
```
1. Owner revokes share via app
   └─ DELETE device_shares row
   
2. Backend: device_shares realtime event fires
   
3. DeviceAccessWatcher receives event
   └─ Calls listSharedDevices()
   └─ Device not found in result
   └─ Broadcasts: revoked.add(macAddress)
   
4. Guest's ShareRevokeListener receives revoked event
   └─ Shows: "Quyền truy cập thiết bị đã bị thu hồi"
   └─ Executes: popUntil((route) => route.isFirst)
   └─ All device screens pop → Back to device list
```

#### Scenario B: Ownership Transfer
```
1. Owner transfers device to another account
   └─ UPDATE devices SET user_id = new_user_id
   
2. Backend: devices realtime event fires
   
3. DeviceAccessWatcher receives event
   └─ Calls listDevices(currentUserId)
   └─ Device not found (user_id changed)
   └─ Broadcasts: revoked.add(macAddress)
   
4. Guest's ShareRevokeListener receives revoked event
   └─ Shows: "Quyền truy cập thiết bị đã bị thu hồi"
   └─ Executes: popUntil((route) => route.isFirst)
   └─ All device screens pop → Back to device list
```

### Edge Cases Handled

| Case | Solution |
|------|----------|
| Multiple screens open | `popUntil((route) => route.isFirst)` pops all at once |
| Duplicate stream events | Stream seed skips first (snapshot) event |
| Offline scenarios | App can't detect until reconnected, but refresh will catch it |
| Navigator context safety | Checks `context.mounted` before pop |
| Access race conditions | Multiple listeners safe due to global broadcast |

### Testing Procedure

**Prerequisites:**
- 2 devices (one for owner, one for guest)
- Existing share between them

**Test Case 1: Share Revoke**
1. Guest opens dashboard → sensor capacity → sensor config
2. Owner revokes share via app
3. Expected: All 3 screens auto-close, SnackBar shows, back at device list

**Test Case 2: Ownership Transfer**
1. Guest opens dashboard → sensor capacity → sensor config
2. Owner transfers ownership to another account
3. Expected: All 3 screens auto-close, SnackBar shows, back at device list

### Performance Impact

**Before:** Each screen individually checked access when navigating
**After:** Single global service checks once per change event

**Benefits:**
- Reduced duplicate RPC calls to backend
- Cleaner code with single responsibility
- More efficient network usage
- Better user experience (immediate feedback)

### Files Modified

1. `lib/services/crud_api.dart` - Added deviceChanges() stream
2. `lib/services/device_access_watcher.dart` - New global service (117 lines)
3. `lib/widgets/share_revoke_detector.dart` - Refactored to use global service (41 lines)
4. `lib/screens/splash_screen.dart` - Initialize watcher on startup
5. `lib/screens/diagnostics_screen.dart` - Fix device ID (device.macAddress)

### Breaking Changes
None - API is backward compatible.

### Future Improvements
- Add retry logic for failed access checks
- Persist last known state for offline support
- Add analytics for access revoke events
