# Debug Logging Guide - Device Access Revocation

## Overview
Added comprehensive debug logging throughout the app to track when and why a device access is revoked or ownership is transferred. This will help diagnose issues with the automatic logout feature.

## Logging Locations

### 1. **DeviceAccessWatcher** (`lib/services/device_access_watcher.dart`)
Main service that detects when device access changes.

**Key log prefixes: `[DeviceAccessWatcher]`**

#### Listeners:
- `_startShareListener()`: 🔔 Logs when share stream is started and change events arrive
- `_startDeviceListener()`: 🔔 Logs when device stream is started and change events arrive

#### Access Check:
- `_checkAccess()`: 
  - Logs current cached devices
  - Logs devices from server (owned + shared)
  - Logs which devices are still accessible
  - ⚠️  Logs when a device is REVOKED
  - ✅ Logs devices that remain accessible
  - Logs when repository is refreshed

**Example log flow when access is revoked:**
```
[DeviceAccessWatcher] 🔔 Starting share listener for user: xxx
[DeviceAccessWatcher] 🔔 Share change event received: 1 shares
[DeviceAccessWatcher] Processing share change...
[DeviceAccessWatcher] Checking device access...
[DeviceAccessWatcher] Current cached devices: 1
  - NACENTECH - Water Monitor (84c7bb772310)
[DeviceAccessWatcher] Owned devices from server: 1
  - NACENTECH - Water Monitor (id: xxx)
[DeviceAccessWatcher] Shared devices from server: 0
[DeviceAccessWatcher] Total accessible devices: 1
[DeviceAccessWatcher] ✅ Device still accessible: NACENTECH - Water Monitor
[DeviceAccessWatcher] Repository refreshed
```

When revoked:
```
[DeviceAccessWatcher] ⚠️  DEVICE REVOKED: NACENTECH - Water Monitor (84c7bb772310)
```

---

### 2. **ShareRevokeListener** (`lib/widgets/share_revoke_detector.dart`)
Listens to global device access changes and triggers navigation/logout.

**Key log prefix: `[ShareRevokeListener]`**

#### Flow:
- `start()`: Logs device ID being watched
- Logs each revoke event received with device IDs
- 📱 `_onRevoked()`: Logs when matching device is found
- Logs snackbar display and navigation pops

**Example log flow when device needs to logout:**
```
[ShareRevokeListener] Starting for device: 84c7bb772310
[ShareRevokeListener] Received revoke event for: 84c7bb772310 (listening for: 84c7bb772310)
[ShareRevokeListener] ⚠️  MATCH! Device revoked: 84c7bb772310
[ShareRevokeListener] 📱 Executing _onRevoked for 84c7bb772310
[ShareRevokeListener] Showing snackbar
[ShareRevokeListener] Popping to first route
[ShareRevokeListener] Checking route: /dashboard
```

---

### 3. **DeviceTransferWatcher** (`lib/services/device_transfer_watcher.dart`)
Handles ownership transfer notices (when device ownership changes).

**Key log prefix: `[Transfer]`**

#### Flow:
- `start()`: 🔔 Logs when transfer watcher starts
- `_process()`: Logs transfer notices received
- `_handle()`: 
  - Logs device being checked
  - Logs if device is still owned
  - ⚠️  Logs when device is no longer owned
  - Logs when transfer notice is deleted

**Example log flow when ownership transfers:**
```
[Transfer] 🔔 Starting transfer watcher for user: xxx
[Transfer] 🔔 Transfer notice received: 1 rows
[Transfer] Processing 1 transfer notices
[Transfer] Notice: id=yyy, mac=84c7bb772310
[Transfer] Handling notice for device: 84c7bb772310
[Transfer] Device name: NACENTECH - Water Monitor
[Transfer] Still owned by current user? false
[Transfer] ⚠️  Device 84c7bb772310 is no longer owned - forgetting
[Transfer] Deleted transfer notice: yyy
```

---

## How to Use These Logs

### Scenario 1: Device Access Not Revoked When It Should Be
1. Owner revokes guest access
2. Watch for `[DeviceAccessWatcher]` logs
3. Check if `⚠️  DEVICE REVOKED` appears
4. If not appearing, check if share stream event is received: `🔔 Share change event received`

### Scenario 2: Guest App Not Logging Out
1. Guest is in device details screen
2. Owner revokes access
3. Watch for `[ShareRevokeListener]` logs
4. Check if `⚠️  MATCH! Device revoked` appears
5. If not, check if `📱 Executing _onRevoked` appears
6. If appearing, app is logging out correctly; if not, there's a bug in the navigation

### Scenario 3: Ownership Transfer Issues
1. Device ownership is transferred to new owner
2. Watch for `[Transfer]` logs
3. Check if `⚠️  Device xxx is no longer owned` appears
4. Verify guest app also logs out (should work same as revoke)

---

## Log Filter Shortcuts

To filter logs while running app:

```bash
# Only DeviceAccessWatcher
adb logcat | grep "\[DeviceAccessWatcher\]"

# Only access revocation events
adb logcat | grep -E "REVOKED|MATCH!"

# Only transfer events
adb logcat | grep "\[Transfer\]"

# All device access related
adb logcat | grep -E "\[DeviceAccessWatcher\]|\[ShareRevokeListener\]|\[Transfer\]"

# Only errors
adb logcat | grep "❌"

# Only important events
adb logcat | grep -E "⚠️|🔔|📱|✅|❌"
```

---

## Emoji Reference

- 🔔 Stream event received
- ⚠️  Device access issue (revoked, lost ownership)
- 🔴 Check access in progress
- 📱 Navigation/screen action
- ✅ Device still accessible
- ❌ Error occurred
- 🔍 Checking something

---

## Expected Log Order for Revocation

**When owner revokes guest access:**

1. `[DeviceAccessWatcher] 🔔 Share change event received`
2. `[DeviceAccessWatcher] Processing share change...`
3. `[DeviceAccessWatcher] Checking device access...`
4. `[DeviceAccessWatcher] ⚠️  DEVICE REVOKED: ...`
5. `[ShareRevokeListener] Received revoke event for: ...`
6. `[ShareRevokeListener] ⚠️  MATCH! Device revoked: ...`
7. `[ShareRevokeListener] 📱 Executing _onRevoked`
8. `[ShareRevokeListener] Showing snackbar`
9. `[ShareRevokeListener] Popping to first route`

If this order is broken, there's a specific point of failure.

---

## Notes

- All logs use `debugPrint()` so they appear in Flutter's debug console
- The app logs both realtime updates and what it fetches from the server
- Each major step is logged so you can see the exact flow
- Timestamps can help identify delays between events
