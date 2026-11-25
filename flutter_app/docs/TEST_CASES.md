# Comprehensive Test Cases for Device Access Control

## Test Matrix

### Case 1: Guest - Share Revoke
**Setup:**
- Owner shares device with Guest
- Guest accepts and opens multiple screens

**Action:**
- Owner revokes the share (delete from device_shares)

**Expected Behavior:**
- ✅ Guest's device list: Device disappears
- ✅ Guest's open screens (dashboard → sensor config):
  - Show SnackBar: "Quyền truy cập thiết bị đã bị thu hồi"
  - Auto-pop all screens back to device list
- ✅ MQTT: Guest's subscription to device is removed

**Current Implementation:** ✅ HANDLED
- `DeviceAccessWatcher._startShareListener()` → listens to device_shares changes
- `_checkAccess()` → calls `listSharedDevices()` → device not found
- `revoked.add(macAddress)` → `ShareRevokeListener` pops screens

---

### Case 2: Guest - Ownership Transfer (Owner → Stranger)
**Setup:**
- Owner shares device with Guest
- Guest accepts and opens multiple screens
- Owner has the device in their device list

**Action:**
- Owner transfers ownership to Stranger (UPDATE devices.user_id)

**Expected Behavior:**
- ✅ Guest's device list: Device disappears (no longer shared)
- ✅ Guest's open screens (dashboard → sensor config):
  - Show SnackBar: "Quyền truy cập thiết bị đã bị thu hồi"
  - Auto-pop all screens back to device list
- ✅ Owner's device list: Device disappears (no longer owned)
- ✅ Owner's open screens (if any):
  - Show SnackBar: "Quyền truy cập thiết bị đã bị thu hồi"
  - Auto-pop all screens back to device list
- ✅ MQTT: Both Guest's and Owner's subscriptions removed

**Current Implementation:** ✅ HANDLED
- `DeviceAccessWatcher._startDeviceListener()` → listens to devices table changes
- When Owner updates devices.user_id:
  - Guest's `_checkAccess()` → `listSharedDevices()` → device not found (share gone)
  - Owner's `_checkAccess()` → `listDevices()` → device not found (user_id changed)
- Both emit `revoked.add(macAddress)` → Both get kicked out

---

### Case 3: Owner - Ownership Transfer (without guest)
**Setup:**
- Owner has device
- Owner opens multiple screens
- No guest access

**Action:**
- Owner transfers ownership to Stranger (UPDATE devices.user_id)

**Expected Behavior:**
- ✅ Owner's device list: Device disappears
- ✅ Owner's open screens (dashboard → sensor config):
  - Show SnackBar: "Quyền truy cập thiết bị đã bị thu hồi"
  - Auto-pop all screens back to device list
- ✅ MQTT: Owner's subscription removed

**Current Implementation:** ✅ HANDLED
- `DeviceAccessWatcher._startDeviceListener()` → listens to devices table
- Owner's `_checkAccess()` → `listDevices()` → device not found
- `revoked.add(macAddress)` → Owner's `ShareRevokeListener` pops screens

---

### Case 4: Guest - Device Deleted by Owner
**Setup:**
- Owner shares device with Guest
- Guest accepts and opens screens

**Action:**
- Owner deletes the device (DELETE from devices table)

**Expected Behavior:**
- ✅ Guest's device list: Device disappears
- ✅ Guest's open screens:
  - Show SnackBar: "Quyền truy cập thiết bị đã bị thu hồi"
  - Auto-pop all screens
- ✅ Owner's device list: Device disappears
- ✅ Owner's open screens:
  - Show SnackBar: "Quyền truy cập thiết bị đã bị thu hồi"
  - Auto-pop all screens

**Current Implementation:** ✅ HANDLED
- Deletion is a change to devices table
- Both Guest and Owner will get kicked via same mechanism

---

### Case 5: Guest - Device Goes Offline (Edge Case)
**Setup:**
- Guest accessing device via MQTT

**Action:**
- Device loses connectivity
- Device stays in database but offline

**Expected Behavior:**
- ✅ Guest can still navigate/view in app (device is still in DB)
- ✅ MQTT commands fail (device offline)
- ✓ No auto-pop (not a revoke/transfer)
- ✓ SnackBar shows: "Ngoại tuyến" status chip

**Current Implementation:** ✅ CORRECT
- Offline status is not an access loss
- DeviceAccessWatcher doesn't trigger
- Only `DevicePresence` updates online status

---

### Case 6: Concurrent Actions
**Setup:**
- Guest opens dashboard
- Owner in another screen revokes share AND transfers ownership

**Action:**
- Multiple stream events fire

**Expected Behavior:**
- ✅ Guest gets ONE revoked event (or multiple, but all trigger same action)
- ✅ Screens pop correctly
- ✓ No duplicate SNACKBARs (only last one visible)
- ✓ No race conditions in pop

**Current Implementation:** ⚠️ MINOR ISSUE
- If multiple events fire in quick succession
- Multiple SnackBars might show (only last one visible anyway)
- Could optimize with debounce if needed

---

### Case 7: Flaky Network - Multiple Reconnects
**Setup:**
- Guest accessing device

**Action:**
- Network disconnects and reconnects multiple times

**Expected Behavior:**
- ✓ On each reconnect, streams resume
- ✅ If access revoked during offline period, detected on reconnect
- ✓ SnackBar shows "Quyền truy cập thiết bị đã bị thu hồi"
- ✅ Screens pop

**Current Implementation:** ✅ HANDLED
- Streams auto-reconnect via Supabase
- `_checkAccess()` runs on each event
- No special handling needed

---

## Implementation Verification

### Test Checklist

- [ ] **Share Revoke**
  - [ ] Run Case 1
  - [ ] Verify: Guest sees SnackBar + auto-pop
  - [ ] Verify: Device list updated
  - [ ] Verify: MQTT unsubscribed

- [ ] **Ownership Transfer (with guest)**
  - [ ] Run Case 2 (all users)
  - [ ] Verify: Guest sees SnackBar + auto-pop
  - [ ] Verify: Owner sees SnackBar + auto-pop
  - [ ] Verify: Both device lists updated
  - [ ] Verify: Both MQTT unsubscribed

- [ ] **Ownership Transfer (no guest)**
  - [ ] Run Case 3
  - [ ] Verify: Owner sees SnackBar + auto-pop
  - [ ] Verify: Device list updated
  - [ ] Verify: MQTT unsubscribed

- [ ] **Device Deletion**
  - [ ] Run Case 4
  - [ ] Verify: Both users see SnackBar + auto-pop

- [ ] **Offline Status**
  - [ ] Run Case 5
  - [ ] Verify: Device shows offline
  - [ ] Verify: NO auto-pop (intentional)

- [ ] **Concurrent Actions**
  - [ ] Run Case 6
  - [ ] Verify: Screens pop correctly
  - [ ] Verify: No race conditions

- [ ] **Network Flakiness**
  - [ ] Run Case 7
  - [ ] Verify: Streams reconnect
  - [ ] Verify: Changes detected

---

## Risk Assessment

| Risk | Severity | Mitigation | Status |
|------|----------|-----------|--------|
| Race condition between listDevices and pop | Medium | Stream seed + order of operations | ✅ Mitigated |
| Multiple SnackBars on concurrent events | Low | Only last one visible anyway | ✓ Acceptable |
| NetworkException during _checkAccess | Medium | Try-catch wraps entire block | ✅ Mitigated |
| Stale _repository.devices cache | Medium | Call refresh() after check | ✅ Fixed |
| Context.mounted check missing | High | All pops check context.mounted | ✅ Implemented |
| Memory leak from StreamController | Low | dispose() closes stream | ✅ Implemented |

---

## Code Quality

**DeviceAccessWatcher Implementation Score: 8/10**

Strengths:
- ✅ Unified broadcast mechanism
- ✅ Proper stream seed to skip snapshot
- ✅ Error handling with try-catch
- ✅ Proper cleanup in dispose()
- ✅ Single responsibility

Improvements needed:
- ⚠️ Could add debounce for concurrent events
- ⚠️ Could log more detailed events for analytics
- ⚠️ Could add retry logic for failed checks

---

## Deployment Checklist

Before shipping to production:

- [ ] Run all 7 test cases
- [ ] Verify no console errors in Flutter logs
- [ ] Test on actual device (not emulator)
- [ ] Test with real Supabase realtime (not mock)
- [ ] Monitor crash logs for first 24 hours
- [ ] Gather user feedback on auto-pop behavior

---

## Documentation for QA

### How to Test Device Access Revoke

1. **Setup:**
   - Create 2 test accounts (Alice = owner, Bob = guest)
   - Log into device1 as Alice, device2 as Bob

2. **Test Share Revoke:**
   - Alice: Device list → Select device → Share → Enter Bob's email
   - Alice: See share created
   - Bob: Device list → Should see new share notification
   - Bob: Accept share → Device appears in list
   - Bob: Open Dashboard → Open Sensor Config (deep nested screen)
   - Alice: Device list → Select device → Revoke → Select Bob's share → Confirm
   - Bob: Should see SnackBar + auto-pop to device list

3. **Test Ownership Transfer:**
   - Create Account C (Charlie)
   - Alice: Device list → Device settings → Transfer ownership → Select Charlie
   - Alice: Confirm transfer
   - Alice: Should see SnackBar + auto-pop (if in device screens)
   - Bob (if still has share): Should see SnackBar + auto-pop (share invalid now)
   - Charlie: Refresh device list → Device appears as owned

4. **Expected Logs:**
   ```
   [DeviceAccessWatcher] Device stream error: ... (if connection lost)
   [ShareRevokeListener] Stream error: ... (if connection lost)
   Quyền truy cập thiết bị đã bị thu hồi (SnackBar message)
   ```
