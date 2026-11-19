# Single Share Stream Solution

## Problem
- Host listen `guest_id = userId` → chỉ nhận được khi host là GUEST
- Khi host là OWNER (revoke) → stream không trigger → host không thấy status thay đổi
- Dùng 2 stream riêng biệt → khó sync, logic phức tạp

## Solution
**Single unified stream** cho tất cả shares của user (cả guest & owner role)

## Implementation

### 1. CrudApi - New Stream Method
```dart
static Stream<List<Map<String, dynamic>>> myAllShares() {
  final userId = CrudApi.userId;
  
  // Stream entire device_shares table
  return _db
      .from('device_shares')
      .stream(primaryKey: ['id'])
      .order('updated_at', ascending: false)
      // Client-side filter: only shares where user is guest_id OR owner_id
      .map((rows) => [
        for (final row in rows)
          if (row['guest_id'] == userId || row['owner_id'] == userId) row,
      ]);
}
```

**Cách hoạt động:**
- Subscribe vào stream tất cả `device_shares` table changes
- Server broadcast mỗi khi bất kỳ row nào thay đổi
- Client-side filter: chỉ giữ lại rows liên quan tới user (guest hoặc owner)
- Mỗi khi status thay đổi (guest accept, host revoke, etc) → đều trigger reload

### 2. DeviceListScreen - Use Single Stream
```dart
// Thay thế 2 stream riêng (_sharesSub + _mySharesSub) bằng 1 stream
_sharesSub = CrudApi.myAllShares().listen(
  (event) {
    if (!_sharesSeeded) {
      _sharesSeeded = true;
      return;
    }
    // Reload khi status thay đổi (không phân biệt guest/owner role)
    _loadInvitations().then((_) {
      if (mounted) unawaited(_repository.refresh());
    });
  },
);
```

## Flow (All Cases)

```
📱 HOST APP                    DATABASE                     📱 GUEST APP
─────────────────────────────────────────────────────────────────────────

1. HOST SENDS INVITATION
   Host click "Chia sẻ"
      ↓
   INSERT device_shares: status=pending
      ↓
   Stream trigger (host watch as OWNER)
      ↓
   Host UI: "Đang chờ" ✅
                                                            ← GUEST receives invite
                                                            Stream trigger (guest watch as GUEST)
                                                            Guest UI: "Lời mời chờ duyệt"

2. GUEST ACCEPTS
                                                            Guest click "Chấp nhận"
                                                               ↓
                                                            UPDATE status=accepted
                                                               ↓
                                                            Stream trigger
                                                               ↓
                                                            Guest UI: "Đã chấp nhận" ✅
   
   ← Stream also triggers on HOST side (OWNER watching)
   Host UI: "Đã chấp nhận" ✅

3. HOST REVOKES
   Host click "Thu hồi"
      ↓
   UPDATE status=revoke_waiting
      ↓
   Trigger broadcast 'share_revoke_waiting' to guest
      ↓
   Stream trigger (host watch as OWNER)
      ↓
   Host UI: "Đang chờ xác nhận" ✅
                                                            ← GUEST receives Realtime event
                                                            ShareRevokeListener auto-confirm
                                                               ↓
                                                            UPDATE status=revoked
                                                               ↓
                                                            Trigger broadcast 'share_revoked' to host
                                                               ↓
                                                            Guest UI: Show popup & logout
   
   ← Stream trigger (host watch as OWNER)
   HostShareRevokeConfirmListener receive 'revoked' event
      ↓
   Auto-delete share
      ↓
   Host UI: Share disappears ✅

4. GUEST SELF-DELETES (Alternative)
                                                            Guest swipe delete or click remove
                                                               ↓
                                                            DELETE from device_shares
                                                               ↓
                                                            Stream trigger
                                                               ↓
                                                            Guest UI: Share gone ✅
   
   ← Stream also triggers on HOST side
   Host UI: Share disappeared ✅
```

## Why This Works

✅ **Single stream** catches ALL changes (guest accept, host revoke, guest delete)
✅ **Status is source of truth** - no need to track who initiated the action
✅ **Realtime sync** - both sides see changes immediately
✅ **Simple logic** - no need to maintain 2 separate streams
✅ **Flexible** - handles all scenarios (guest self-delete, host delete, etc)

## Status Values
- `pending` - đang chờ duyệt
- `accepted` - đã chấp nhận (normal sharing)
- `revoke_waiting` - host revoke, chờ guest xác nhận
- `revoked` - guest confirmed revoke, host auto-delete

## Files Changed
- `lib/services/crud_api.dart` - Added `myAllShares()` stream method
- `lib/screens/device_list_screen.dart` - Use single stream instead of 2 separate
- `lib/widgets/share_revoke_detector.dart` - Has `HostShareRevokeConfirmListener` for Realtime events
