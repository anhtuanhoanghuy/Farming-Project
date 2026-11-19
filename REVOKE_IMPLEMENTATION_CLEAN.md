# Revoke Flow Implementation - CLEAN SUMMARY

## Flow Definition

**Host Thu Hồi Device:**
```
1. Host click "Thu hồi" → revoke_share() sets status='revoke_waiting'
2. Guest's stream listener (dashboard) detects revoke_waiting → auto-calls confirmRevoke()
3. confirmRevoke() sets status='revoked'
4. Host's stream listener (share dialog) detects revoked → silent delete + reload UI
```

**Guest Tự Rời:**
```
1. Guest click "Rời" on accepted shared device → guest_remove_share()
2. Directly deletes the share record
```

## Database (Supabase)

**Current State:**
- ✅ `device_shares` table with 7 columns (id, device_id, owner_id, guest_id, status, created_at, updated_at)
- ✅ Constraint allows: pending, accepted, declined, revoke_waiting, revoked
- ✅ Table in `supabase_realtime` publication (streams work)
- ✅ Functions exist: revoke_share, confirm_revoke, delete_revoked_share, respond_share
- ❌ Function MISSING: guest_remove_share

**SQL to Run:**
- File: `document/add_guest_remove_share.sql`
- Action: Run on Supabase SQL editor to add guest_remove_share function

**Triggers (Don't touch):**
- `device_shares_set_updated_at` - maintains updated_at timestamp
- `device_share_removal_broadcast` - broadcasts on DELETE
- `device_shares_broadcast_removed` - cleanup on delete

## Dart Changes

### lib/services/crud_api.dart
✅ Added `guestRemoveShare(String shareId)` - calls guest_remove_share RPC

### lib/screens/dashboard_screen.dart (Guest auto-confirm)
✅ Guest stream listener on guest_id:
  - Detects revoke_waiting status
  - Auto-calls confirmRevoke() silently
  - Cleaned up logging

### lib/screens/device_list_screen.dart (Guest UI)
✅ Track `_sharedDevices` (accepted shares)
✅ Load accepted shares in `_loadInvitations()`
✅ Added `_SharedDevicesDropdown` widget:
  - Shows "Thiết bị được chia sẻ" section
  - Expandable list of accepted shared devices
  - "Rời" button to self-remove
✅ Added `_removeSharingFromDevice()` callback

### lib/widgets/share_device_dialog.dart (Host auto-delete)
✅ Host stream listener on owner_id:
  - Detects revoked/declined status
  - Auto-calls `_silentDeleteShare()` without UI reload
  - Then reloads shares in setState (normal reload)

## Testing Checklist

Before testing, **RUN THE SQL FILE** on Supabase.

Then hot restart Flutter app:
1. **Host Thu Hồi:**
   - Open Share dialog
   - See guest in list with "Chấp nhận" status
   - Click "Thu hồi"
   - Logs: revoke_share() called
   - UI shows "Đang chờ xác nhận thu hồi"

2. **Guest Auto-Confirm (happens on guest side):**
   - Logs: "[DashboardScreen] Guest auto-confirm triggered"
   - Share status changes to "revoked"

3. **Host Auto-Delete (silent):**
   - Logs: "[ShareDeviceDialog] Silent delete successful"
   - After ~2 sec, share disappears from list
   - Reload popup: share gone

4. **Guest Self-Remove:**
   - Device list shows "Thiết bị được chia sẻ" section
   - Lists accepted shares
   - Click "Rời"
   - Share deleted from database
   - Guest's device list refreshes automatically

## Files Changed
- ✅ `lib/services/crud_api.dart` - guestRemoveShare()
- ✅ `lib/screens/dashboard_screen.dart` - guest stream listener
- ✅ `lib/screens/device_list_screen.dart` - shared devices UI
- ✅ `lib/widgets/share_device_dialog.dart` - silent delete + reload
- 📄 `document/add_guest_remove_share.sql` - SQL function (TO RUN)

## Status
🟡 **Waiting for SQL execution** - guest_remove_share function needs to be created on Supabase
