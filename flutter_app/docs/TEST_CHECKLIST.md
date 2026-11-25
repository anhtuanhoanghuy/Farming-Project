# Share Revoke Detection - Test Checklist

## Build Verification ✅
- [x] Flutter analyze: 0 compilation errors
- [x] All imports present in 5 device screens
- [x] All `checkAccessNow()` calls in place
- [x] Device access watcher properly implements both stream and manual check

## Functional Tests (To Be Performed)

### Test 1: Revoke from Host App - Immediate Logout
**Setup:**
- Guest app opened and viewing DiagnosticsScreen
- Host app open to same device

**Steps:**
1. On Host app: Click "Rằng sẽ chia sẻ" or similar to open share list
2. On Host app: Click revoke/thu hồi button for guest user
3. Observe Guest app

**Expected Result:**
- ✅ Guest app should immediately logout from DiagnosticsScreen
- ✅ Snackbar shows: "Quyền truy cập thiết bị đã bị thu hồi"
- ✅ Guest app returns to device list screen
- ✅ Debug log shows: `[ShareRevokeListener] MATCH! Device revoked`

**Actual Result:**
- [ ] Logout immediate? Yes / No / Delayed?
- [ ] Snackbar shown? Yes / No
- [ ] Back to device list? Yes / No
- [ ] Debug logs present? Yes / No

---

### Test 2: Revoke from Other Host - Fallback Check
**Setup:**
- Guest app NOT viewing device (revoke happens while in background)
- Host app revokes access
- Guest app still running in background

**Steps:**
1. On Host app: Revoke guest access
2. Guest app still running but not on device screen
3. Guest user opens DiagnosticsScreen again

**Expected Result:**
- ✅ `checkAccessNow()` called in `initState()`
- ✅ App detects access lost
- ✅ Screen immediately closes and shows snackbar
- ✅ Debug log shows: `[DeviceAccessWatcher] ⚠️  DEVICE REVOKED`

**Actual Result:**
- [ ] Access check runs? Yes / No
- [ ] Revoke detected? Yes / No
- [ ] Logout happens? Yes / No
- [ ] Debug logs present? Yes / No

---

### Test 3: Ownership Transfer - New Owner Removes Old Owner
**Setup:**
- Guest app logged in as Owner1
- Owner1 and Owner2 on device (shared)
- Owner2 becomes new owner via transfer

**Steps:**
1. Owner1 app viewing device screen
2. Owner2 completes ownership transfer
3. Owner1 becomes guest (no longer owner)
4. Owner2 revokes Owner1's access

**Expected Result:**
- ✅ Owner1's stream listener receives revoke event
- ✅ Owner1 app auto-logout from device screen
- ✅ Owner1 returns to device list
- ✅ Owner1 no longer sees device in list

**Actual Result:**
- [ ] Stream event received? Yes / No
- [ ] Logout happens? Yes / No
- [ ] Device removed from list? Yes / No

---

### Test 4: Multiple Device Screens - Logout All
**Setup:**
- Guest app viewing multiple device screens in nested navigation
  - Devices List → DeviceA (DiagnosticsScreen) → Click to details

**Steps:**
1. Guest navigated to: Device List → DeviceA → Diagnostics
2. Host revokes access to DeviceA
3. Observe nested screen closure

**Expected Result:**
- ✅ All nested screens for DeviceA close
- ✅ Return directly to Device List
- ✅ Single snackbar shown
- ✅ No orphaned screens left

**Actual Result:**
- [ ] All screens closed? Yes / No
- [ ] Back to device list? Yes / No
- [ ] Single snackbar? Yes / No
- [ ] No residual screens? Yes / No

---

### Test 5: No Polling - Battery Optimization
**Setup:**
- Guest app running and viewing device screen
- No revoke event sent

**Steps:**
1. Open Device screen
2. Leave app idle for 2 minutes
3. Check logs and battery

**Expected Result:**
- ✅ No repeated "Checking device access" logs every 10 seconds
- ✅ Only single "Checking access on entry" log at screen open
- ✅ Stream listener running in background (minimal battery drain)
- ✅ No network requests during idle time

**Actual Result:**
- [ ] No periodic logs? Yes / No
- [ ] Single entry check? Yes / No
- [ ] Stream active? Yes / No
- [ ] No network activity? Yes / No

---

## Debug Log Inspection

### Log Output Verification
```
// When entering DiagnosticsScreen:
I/flutter: [DiagnosticsScreen] Checking access on entry for device: 84c7bb772310
I/flutter: [DeviceAccessWatcher] Checking device access...
I/flutter: [DeviceAccessWatcher] Current cached devices: 2
I/flutter: [DeviceAccessWatcher] Owned devices from server: 1
I/flutter: [DeviceAccessWatcher] Shared devices from server: 1

// When host revokes:
I/flutter: [DeviceAccessWatcher] Share change event received: 0 shares
I/flutter: [DeviceAccessWatcher] Processing share change...
I/flutter: [DeviceAccessWatcher] ⚠️  DEVICE REVOKED: Tủ điều khiển (84c7bb772310)
I/flutter: [DeviceAccessWatcher] Emitting revoke for device: 84c7bb772310
I/flutter: [ShareRevokeListener] MATCH! Device revoked: 84c7bb772310
I/flutter: [ShareRevokeListener] 📱 Executing _onRevoked for 84c7bb772310
I/flutter: [ShareRevokeListener] Popping to first route
```

- [ ] Entry log present? Yes / No
- [ ] Access check runs? Yes / No
- [ ] Revoke detected? Yes / No
- [ ] Match event fires? Yes / No
- [ ] Logout executes? Yes / No

---

## Regression Testing

### Verify Existing Features Still Work
- [ ] Device list displays correctly
- [ ] Can open DiagnosticsScreen without issue
- [ ] Can open ConsoleScreen without issue
- [ ] Can open LoadControlScreen without issue
- [ ] Can open SensorConfigScreen without issue
- [ ] Can open SensorCapacityScreen without issue
- [ ] Screen navigation works
- [ ] Back button works
- [ ] Other app features unaffected

---

## Performance Checklist
- [ ] No ANR (Application Not Responding) errors
- [ ] No frame drops when opening screens
- [ ] No memory leaks when closing screens
- [ ] Battery drain acceptable (no continuous polling)
- [ ] Network usage minimal (stream only, not polling)

---

## Edge Cases

### Test 6: Rapid Revoke/Share Cycles
**Steps:**
1. Host revokes
2. Quickly share again
3. Quickly revoke again

**Expected Result:**
- ✅ App handles state changes correctly
- ✅ No race conditions
- ✅ Final state matches server

**Actual Result:**
- [ ] State changes handled? Yes / No
- [ ] No crashes? Yes / No
- [ ] Correct final state? Yes / No

---

### Test 7: Poor Network Connection
**Setup:**
- Slow/intermittent network

**Steps:**
1. Guest viewing device screen on poor connection
2. Host revokes
3. Network drops for 5 seconds

**Expected Result:**
- ✅ Revoke eventually detected (stream reconnects)
- ✅ No crashes or hang
- ✅ App remains responsive

**Actual Result:**
- [ ] Handles poor connection? Yes / No
- [ ] Eventually detects revoke? Yes / No
- [ ] No crashes? Yes / No

---

### Test 8: App in Background
**Setup:**
- Guest app in background (not visible)
- Host revokes

**Steps:**
1. Guest opens another app (app goes background)
2. Host revokes access
3. Guest returns to app
4. Guest navigates to device screen

**Expected Result:**
- ✅ `checkAccessNow()` on screen entry detects loss
- ✅ Logout happens immediately
- ✅ User never sees revoked device

**Actual Result:**
- [ ] Background handling works? Yes / No
- [ ] Entry check detects loss? Yes / No
- [ ] Logout happens? Yes / No

---

## Success Criteria
- [x] Build compiles with 0 errors
- [ ] All 8 test scenarios pass
- [ ] No regressions in existing features
- [ ] Debug logs show proper event flow
- [ ] No excessive battery drain
- [ ] Edge cases handled gracefully

---

## Notes for QA
1. Use `adb logcat | grep -i "flutter\|revoke\|access"` to filter logs
2. Test on both low-end and high-end devices
3. Test with various network conditions (WiFi, 4G, 3G)
4. Test with multiple guest users simultaneously
5. Enable developer options for detailed logging
6. Capture logs before/during/after each test
