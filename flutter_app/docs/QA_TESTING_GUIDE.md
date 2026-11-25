# QA Testing Guide - Device Access Control

## 🎯 Test Objectives

Verify that when a device owner revokes share access or transfers device ownership, all users are automatically logged out from device-specific screens with unified behavior across all scenarios.

---

## 📋 Pre-Test Setup

### Environment Requirements
- [ ] Flutter app compiled and running
- [ ] Supabase backend accessible
- [ ] 2-3 test devices (mobile/emulator)
- [ ] 2 test accounts (owner + guest)
- [ ] Real device or emulator with shared device configured

### Test Account Setup
```
Account A (Owner):
- Email: owner@test.com
- Role: Device owner
- Devices: 1 shared device configured

Account B (Guest):
- Email: guest@test.com
- Role: Guest user
- Access: Shared device from Account A
```

---

## 🧪 Test Cases

### Group 1: Share Revoke Tests

#### Test 1.1: Share Revoke - Single Screen
**Prerequisite:** Device shared with Guest, Guest viewing Dashboard

**Steps:**
1. Guest opens app and navigates to Device → Dashboard
2. Owner: Revoke guest access from share settings
3. Observe Guest's screen

**Expected Behavior:**
- [ ] SnackBar shows "Quyền truy cập..." message
- [ ] Dashboard screen automatically pops
- [ ] Device removed from device list
- [ ] No error messages
- [ ] Guest returns to home screen

**Result:** ___________  Pass / Fail

---

#### Test 1.2: Share Revoke - Nested Screens
**Prerequisite:** Device shared with Guest, Guest in Sensor Config screen

**Steps:**
1. Guest opens app
2. Guest: Device → Sensor Capacity → Sensor Config (3 screens deep)
3. Owner: Revoke guest access
4. Observe Guest's screen

**Expected Behavior:**
- [ ] SnackBar appears on top
- [ ] All 3 screens pop simultaneously
- [ ] Guest returns to home (device list)
- [ ] No intermediate screens visible during pop
- [ ] Device removed from list

**Result:** ___________  Pass / Fail

---

#### Test 1.3: Share Revoke - Multiple Screens Open
**Prerequisite:** Device shared with Guest, Guest has 2 devices open

**Setup:**
1. Configure 2 shared devices (Device X, Device Y)
2. Guest adds both to favorites
3. Guest opens Device X → Dashboard (keep open)
4. Guest opens Device Y → Sensor Config (via tab switch)

**Steps:**
1. Owner A: Revoke access to Device X
2. Observer: What happens to Guest?
3. Owner B: Revoke access to Device Y
4. Observer: What happens to Guest?

**Expected Behavior:**
- [ ] After step 2: Device X screen pops, Device Y screen still open
- [ ] SnackBar shows for Device X revoke
- [ ] After step 3: Device Y screen pops, return to home
- [ ] SnackBar shows for Device Y revoke
- [ ] No race conditions or crashes

**Result:** ___________  Pass / Fail

---

#### Test 1.4: Share Revoke - Offline Recovery
**Prerequisite:** Device shared with Guest

**Steps:**
1. Guest navigates to Device → Sensor Config
2. Disable network (Airplane mode)
3. Owner: Revoke guest access
4. Guest: Perform some action (should fail gracefully)
5. Re-enable network
6. Wait 2-3 seconds for reconnection

**Expected Behavior:**
- [ ] Offline: No immediate pop (expected)
- [ ] Action fails with network error (expected)
- [ ] After reconnect: SnackBar appears
- [ ] Screen pops back to home
- [ ] Clean error handling, no crash

**Result:** ___________  Pass / Fail

---

### Group 2: Ownership Transfer Tests

#### Test 2.1: Ownership Transfer - Owner Kicked
**Prerequisite:** Owner viewing Device Dashboard

**Setup:**
1. Owner A has Device X
2. Owner A is viewing Device X → Dashboard
3. Guest B has access to Device X

**Steps:**
1. Owner A: Transfer ownership to Owner C
2. Observe Owner A's screen

**Expected Behavior:**
- [ ] SnackBar shows "Quyền truy cập..." message
- [ ] Dashboard screen pops
- [ ] Device removed from Owner A's device list
- [ ] Owner A returns to home

**Result:** ___________  Pass / Fail

---

#### Test 2.2: Ownership Transfer - Guest Kicked
**Prerequisite:** Guest viewing Shared Device

**Setup:**
1. Owner A has Device X, shares with Guest B
2. Guest B viewing Device X → Sensor Config
3. Owner A plans to transfer to Owner C

**Steps:**
1. Owner A: Transfer ownership of Device X to Owner C
2. Observe Guest B's screen

**Expected Behavior:**
- [ ] SnackBar shows "Quyền truy cập..." message
- [ ] Sensor Config screen pops
- [ ] Guest B returns to home
- [ ] Device removed from Guest B's device list
- [ ] No other side effects

**Result:** ___________  Pass / Fail

---

#### Test 2.3: Ownership Transfer - Both Owner & Guest Kicked
**Prerequisite:** 2 devices, 2 screens open

**Setup:**
1. Owner A: Device X (viewing Dashboard)
2. Guest B: Device X (viewing Sensor Config)
3. Same time setup

**Steps:**
1. Owner A: Transfer ownership
2. Wait for events to process

**Expected Behavior:**
- [ ] Both receive SnackBar (possibly at same time)
- [ ] Both screens pop simultaneously or in quick succession
- [ ] No race conditions
- [ ] Both devices removed from their lists
- [ ] No cross-user interference

**Result:** ___________  Pass / Fail

---

#### Test 2.4: Ownership Transfer - Previous Guest Has No Access
**Prerequisite:** Ownership transfer scenario without guest

**Setup:**
1. Owner A: Device X (not shared)
2. Owner A: Viewing Device X → Dashboard

**Steps:**
1. Owner A: Transfer ownership to Owner C
2. Observe Owner A's screen

**Expected Behavior:**
- [ ] SnackBar shows (Owner A not guest to self)
- [ ] Dashboard pops
- [ ] Device removed
- [ ] No special handling needed

**Result:** ___________  Pass / Fail

---

### Group 3: Edge Cases & Error Handling

#### Test 3.1: Device Offline (Not Kicked)
**Prerequisite:** Device exists but is offline

**Steps:**
1. Guest: Navigate to Device → Sensor Capacity
2. Device: Turn off power (device goes offline)
3. Wait 10 seconds
4. Owner: Revoke guest access while device offline
5. Observe Guest's screen

**Expected Behavior:**
- [ ] Screen does NOT pop (device offline ≠ access revoked)
- [ ] No SnackBar
- [ ] Guest can still see device in list
- [ ] Requests to device fail (expected)
- [ ] Later when guest leaves and refreshes, device gone (normal flow)

**Result:** ___________  Pass / Fail

---

#### Test 3.2: Device Deleted (Hard Delete)
**Prerequisite:** Owner has option to delete device completely

**Setup:**
1. Guest: Viewing Device X → Dashboard
2. Owner: Decide to delete entire device

**Steps:**
1. Owner: Delete device X
2. Observe Guest's screen

**Expected Behavior:**
- [ ] SnackBar appears (device lost access)
- [ ] Dashboard pops
- [ ] Device removed from guest's list
- [ ] (Same as revoke from guest's perspective)

**Result:** ___________  Pass / Fail

---

#### Test 3.3: Concurrent Events - Revoke & Delete
**Prerequisite:** Multiple devices, complex scenario

**Setup:**
1. Guest has access to Device X, Y, Z
2. Guest: Navigating between screens

**Steps:**
1. Owner A: Revoke access to Device X
2. Owner B: Revoke access to Device Y
3. Admin: Delete Device Z (hard delete)
4. All at same time (or within 1 second)
5. Observe Guest's screen

**Expected Behavior:**
- [ ] Multiple SnackBars show (possibly stacked)
- [ ] All device screens pop if visible
- [ ] No crash or inconsistent state
- [ ] All 3 devices removed from list
- [ ] Clean UI after event storm

**Result:** ___________  Pass / Fail

---

#### Test 3.4: Flaky Network During Revoke
**Prerequisite:** Network connection is unstable

**Setup:**
1. Guest: Viewing Device → Sensor Config
2. Network: Enable network throttling (2G/3G simulated)

**Steps:**
1. Owner: Revoke access
2. During revoke broadcast, network hiccup (drops 50% packets)
3. Guest: Wait for event to arrive
4. Guest: Try to perform action on screen

**Expected Behavior:**
- [ ] SnackBar eventually appears (stream reconnects)
- [ ] Screen pops after SnackBar
- [ ] No duplicate pops
- [ ] No stuck UI states
- [ ] Graceful degradation

**Result:** ___________  Pass / Fail

---

#### Test 3.5: User Navigates Away Before Pop
**Prerequisite:** User manually navigating

**Setup:**
1. Guest: Device → Sensor Config screen (nested)
2. Owner: Preparing to revoke

**Steps:**
1. Owner: Start revoke
2. Meanwhile, Guest: Manually tap back button (exit screen)
3. Event arrives during/after manual pop

**Expected Behavior:**
- [ ] Screen pops (by Guest's back button first)
- [ ] SnackBar may or may not show (timing dependent)
- [ ] No crash from second pop attempt
- [ ] popUntil() handles already-popped routes gracefully
- [ ] No duplicate navigation

**Result:** ___________  Pass / Fail

---

### Group 4: Multiple Screens Scenarios

#### Test 4.1: Dashboard Screen Revoke
**Steps:**
1. Guest: Navigate to Device → Dashboard
2. Owner: Revoke guest access
3. Verify pop and cleanup

**Expected:** ✓ Pop to home / ✗ Failed

**Result:** ___________  Pass / Fail

---

#### Test 4.2: Sensor Capacity Screen Revoke
**Steps:**
1. Guest: Navigate to Device → Sensor Capacity
2. Owner: Revoke guest access
3. Verify pop and cleanup

**Expected:** ✓ Pop to home / ✗ Failed

**Result:** ___________  Pass / Fail

---

#### Test 4.3: Sensor Config Screen Revoke
**Steps:**
1. Guest: Navigate to Device → Sensor Config
2. Owner: Revoke guest access
3. Verify pop and cleanup

**Expected:** ✓ Pop to home / ✗ Failed

**Result:** ___________  Pass / Fail

---

#### Test 4.4: Load Control Screen Revoke
**Steps:**
1. Guest: Navigate to Device → Load Control
2. Owner: Revoke guest access
3. Verify pop and cleanup

**Expected:** ✓ Pop to home / ✗ Failed

**Result:** ___________  Pass / Fail

---

#### Test 4.5: Diagnostics Screen Revoke
**Steps:**
1. Guest: Navigate to Device → Diagnostics
2. Owner: Revoke guest access
3. Verify pop and cleanup

**Expected:** ✓ Pop to home / ✗ Failed

**Result:** ___________  Pass / Fail

---

## 🔍 Verification Checklist

After each test, verify:

- [ ] No console errors or exceptions
- [ ] No memory leaks (device list clears properly)
- [ ] No duplicate SnackBars
- [ ] SnackBar message is clear and in Vietnamese
- [ ] Screen animation is smooth (no janky pops)
- [ ] No stuck navigation state
- [ ] Device list refreshes correctly
- [ ] MQTT connection cleans up (if applicable)
- [ ] Next navigation works normally (can open another device)
- [ ] Timer/subscriptions cleaned up (no background tasks after pop)

---

## 📊 Test Results Summary

| Test ID | Description | Expected | Result | Notes |
|---------|-------------|----------|--------|-------|
| 1.1 | Share Revoke - Single | PASS | | |
| 1.2 | Share Revoke - Nested | PASS | | |
| 1.3 | Share Revoke - Multiple | PASS | | |
| 1.4 | Share Revoke - Offline | PASS | | |
| 2.1 | Transfer - Owner | PASS | | |
| 2.2 | Transfer - Guest | PASS | | |
| 2.3 | Transfer - Both | PASS | | |
| 2.4 | Transfer - No Guest | PASS | | |
| 3.1 | Device Offline | PASS | | |
| 3.2 | Device Deleted | PASS | | |
| 3.3 | Concurrent Events | PASS | | |
| 3.4 | Flaky Network | PASS | | |
| 3.5 | Manual Navigation | PASS | | |
| 4.1 | Dashboard Screen | PASS | | |
| 4.2 | Sensor Capacity | PASS | | |
| 4.3 | Sensor Config | PASS | | |
| 4.4 | Load Control | PASS | | |
| 4.5 | Diagnostics | PASS | | |

**Total Passed:** __ / 18
**Total Failed:** __ / 18
**Success Rate:** __ %

---

## 🐛 Bug Reporting Template

If a test fails, report using this template:

```
Test ID: [1.2]
Title: Share Revoke - Nested Screens
Status: FAILED

Environment:
- Flutter Version: [X.X.X]
- Device: [iPhone 12 / Android Emulator]
- Supabase Region: [us-east-1]

Expected Behavior:
- All 3 screens pop simultaneously

Actual Behavior:
- Only Dashboard popped, Sensor Capacity still visible

Screenshots:
[Attach screenshot showing bug]

Console Output:
[Paste any error messages from console]

Steps to Reproduce:
1. Navigate to Device → Sensor Capacity → Sensor Config
2. Owner revokes access
3. Observe screen behavior

Additional Notes:
[Any other observations]
```

---

## ✅ Sign-Off Checklist

**Before Deployment:**
- [ ] All 18 test cases passed
- [ ] No critical bugs found
- [ ] No memory leaks
- [ ] No duplicate events
- [ ] All device screens verified
- [ ] Error handling tested
- [ ] Network conditions tested
- [ ] Off-by-one navigation bugs ruled out

**Performance Checks:**
- [ ] SnackBar latency < 500ms
- [ ] Screen pop latency < 300ms
- [ ] No UI jank during events
- [ ] Device list refresh < 1s

**Code Quality:**
- [ ] No analyzer warnings
- [ ] No debug prints in production code
- [ ] Proper error handling
- [ ] Clean code review passed

---

## 📞 Support Contact

If you encounter issues during testing:
1. Check console for error messages
2. Review UNIFIED_LOGIC.md for expected behavior
3. Check TEST_CASES.md for scenario details
4. Collect logs and screenshots
5. Report using bug template above

---

## 🎓 Test Tips

**Pro Tips:**
1. Always clear app data before starting new test
2. Keep two devices side-by-side for owner/guest testing
3. Use device time skip (if supported) to simulate delayed events
4. Monitor Supabase logs for RPC calls
5. Test with real Supabase (not mocks) for best accuracy

**Debugging Tips:**
1. Enable flutter logs: `flutter logs`
2. Search for `[DeviceAccessWatcher]` in logs
3. Search for `[ShareRevokeListener]` in logs
4. Check device_id mismatch (UUID vs MAC address)
5. Verify user_id in Supabase auth

---

**Last Updated:** 2026-11-18
**Version:** 1.0
**QA Lead:** [Your Name]
