# Share Revoke Event Missing - Root Cause Analysis

## Vấn Đề Báo Cáo

**Hiện tượng:**
- Khi **gửi lời mời** (sendInvite) → App khách **bắt được event ngay**
- Khi **thu hồi** (revokeShare) → App khách **không bắt được event**

**Kết quả:**
- Guest phải mở lại màn hình hoặc gửi lời mời lần 2 để logout

---

## Phân Tích Realtime Stream

### Code Subscription Hiện Tại

```dart
// Listen to device_shares table changes for the signed-in user (as guest)
_shareSubscription = CrudApi.shareChanges('guest_id', CrudApi.userId).listen(
  (event) {
    debugPrint('[DeviceAccessWatcher] Share change event received: ${event.length} shares');
    debugPrint('[DeviceAccessWatcher] 📋 Share event details: $event');
    unawaited(_checkAccess());
  }
);
```

**Current Implementation:**
```dart
static Stream<List<Map<String, dynamic>>> shareChanges(
  String column,
  String value,
) => _db
    .from('device_shares')
    .stream(primaryKey: ['id'])
    .eq(column, value);
```

---

## Giả Thuyết - Tại Sao Thu Hồi Không Có Event

### Giả Thuyết 1: Supabase Realtime DELETE Event Behavior ⚠️

**Vấn đề Tiềm Ẩn:**
Supabase Realtime stream có thể hoạt động khác nhau cho INSERT/UPDATE vs DELETE:

- **INSERT/UPDATE:** Phát event với row data mới ✅
- **DELETE:** Có thể không phát event? Hoặc phát event nhưng không có data?

**Dấu Hiệu:**
- Gửi lời mời (INSERT) → Event có data → App nhận được ✅
- Thu hồi (DELETE) → Event không có row → App không nhận được? ❌

**Cách Kiểm Tra:**
Tôi cần xem backend RPC `revoke_share` làm gì:
1. DELETE row từ device_shares?
2. Hay UPDATE status từ 'accepted' → 'revoked'?

---

### Giả Thuyết 2: Stream Filter Not Matching ⚠️

Nếu `revoke_share` **UPDATE** status thay vì DELETE:

```
Before: { id, guest_id, device_id, status: 'accepted', ... }
After:  { id, guest_id, device_id, status: 'revoked', ... }
```

Nhưng `.stream(primaryKey: ['id'])` vẫn được trigger, vì row vẫn tồn tại.

**Vấn đề:**
`.eq('guest_id', userId)` filter vẫn match → Nên event vẫn được phát

**Nhưng có thể:**
- Event được phát nhưng data trong list giống nhau
- Code check `_lastShares?.length == event.length` → Bỏ qua vì "duplicate" ❌

---

### Giả Thuyết 3: Backend Chưa Gửi Event ⚠️

Backend `revoke_share` RPC có thể:
1. Thực hiện DELETE/UPDATE
2. Nhưng **không trigger Realtime notification**

**Vì sao có thể xảy ra:**
- Realtime publication chỉ bao gồm INSERT/UPDATE, không DELETE
- Hoặc RPC function quên `notify trigger`
- Hoặc DELETE không được enable trong Realtime

---

## Cách Kiểm Tra & Debug

### Debug Step 1: Xem Event Khi Gửi Lời Mời

**Bước:**
1. Mở app Host
2. Mở app Guest (đã login)
3. Trên app Host: Click "Gửi lời mời chia sẻ"
4. Xem Guest app logs

**Expected Log:**
```
[DeviceAccessWatcher] 🔔 Share change event received: 1 shares
[DeviceAccessWatcher] 📋 Share event details: [
  {id: xxx, guest_id: yyy, device_id: zzz, status: pending, ...}
]
```

---

### Debug Step 2: Xem Event Khi Thu Hồi

**Bước:**
1. Mở app Host
2. Mở app Guest (đã login, xem DiagnosticsScreen)
3. Trên app Host: Click "Thu hồi" cho guest
4. Xem Guest app logs

**Expected Log:**
```
[DeviceAccessWatcher] 🔔 Share change event received: 0 shares
[DeviceAccessWatcher] 📋 Share event details: []
```

**Actual Log (Vấn đề):**
```
[DeviceAccessWatcher] Share change event KHÔNG được nhận
```

---

### Debug Step 3: Xem Backend RPC

Cần kiểm tra backend:
```sql
-- Hàm revoke_share làm gì?
-- 1. DELETE row?
-- 2. UPDATE status?
-- 3. Có trigger Realtime?
```

**Có thể:**
```sql
CREATE FUNCTION revoke_share(p_share_id UUID) AS $$
BEGIN
  DELETE FROM device_shares WHERE id = p_share_id;
  -- ⚠️ DELETE không trigger Realtime!
END;
$$;
```

**Hoặc:**
```sql
CREATE FUNCTION revoke_share(p_share_id UUID) AS $$
BEGIN
  UPDATE device_shares SET status = 'revoked' WHERE id = p_share_id;
  -- ✅ UPDATE sẽ trigger Realtime
END;
$$;
```

---

## Giải Pháp Khả Thi

### Giải Pháp 1: Thêm Delete Realtime Event ✅

**Backend Change (Backend Team):**

Nếu `revoke_share` DELETE:
```sql
-- Supabase Console → SQL Editor → Run:
ALTER PUBLICATION supabase_realtime ADD TABLE device_shares;
-- Ensure DELETE events are included:
ALTER TABLE device_shares REPLICA IDENTITY FULL;
```

**Result:** DELETE event sẽ được phát như INSERT/UPDATE

---

### Giải Pháp 2: Backend Phát Realtime Event Explicitly ✅

**Backend Change:**

Thay vì dựa vào trigger tự động, backend gửi event explicit:
```sql
CREATE FUNCTION revoke_share(p_share_id UUID) AS $$
BEGIN
  DELETE FROM device_shares WHERE id = p_share_id;
  
  -- Explicitly notify app via custom event
  PERFORM pg_notify('device_access_revoked', 
    json_build_object(
      'guest_id', (SELECT guest_id FROM device_shares WHERE id = p_share_id),
      'device_id', (SELECT device_id FROM device_shares WHERE id = p_share_id)
    )::text
  );
END;
$$;
```

**Result:** App nhận event ngay lập tức

---

### Giải Pháp 3: App Side - Better Event Detection ✅

**App Change (Có thể làm ngay):**

Thay vì chỉ dựa vào stream, hãy:
1. Listen để DELETE event (empty list)
2. Listen để status change event (status = 'revoked')
3. Trigger `checkAccessNow()` cho cả hai

**Hiện Tại:**
```dart
// Only listens to list length change
if (_lastShares?.length == event.length) {
  debugPrint('[DeviceAccessWatcher] 🔄 Share count unchanged, skip');
  return; // ❌ WRONG! Status could change without count change
}
```

**Cải Thiện:**
```dart
// Check if any share status changed OR list changed
bool statusChanged = false;
for (int i = 0; i < event.length && i < (_lastShares?.length ?? 0); i++) {
  if (event[i]['status'] != _lastShares?[i]['status']) {
    statusChanged = true;
    break;
  }
}

if (_lastShares?.length != event.length || statusChanged) {
  _checkAccess(); // ✅ Trigger check on both count and status change
}
```

---

### Giải Pháp 4: Hybrid - Combine App + Backend Fix ✅ (Best)

**Short-term (App Side - Làm Ngay):**
1. Cải thiện event detection (check status change)
2. Thêm polling fallback với interval dài hơn (tùy chọn)

**Long-term (Backend Side):**
1. Đảm bảo DELETE event được phát
2. Hoặc gửi explicit notification

---

## Lộ Trình Khắc Phục

### Ngay Lập Tức (App Side)

**Tôi sẽ làm:**

1. **Enhance event detection** - Check both count AND status change
2. **Add more detailed logging** - Xem event JSON structure
3. **Test with backend team** - Verify what backend RPC actually does

**Code Change:**
```dart
void _startShareListener() {
  _shareSubscription = CrudApi.shareChanges('guest_id', CrudApi.userId).listen(
    (event) {
      debugPrint('[DeviceAccessWatcher] Share event: ${event.length} shares');
      debugPrint('[DeviceAccessWatcher] Event data: $event');
      
      // Check if this is first event (seed)
      if (_lastShares == null) {
        _lastShares = event;
        return;
      }
      
      // ✅ Check BOTH count change AND status change
      bool changed = _lastShares!.length != event.length;
      
      // Also check if any status changed
      if (!changed && _lastShares!.length == event.length) {
        for (int i = 0; i < event.length; i++) {
          if (event[i]['status'] != _lastShares![i]['status']) {
            debugPrint('[DeviceAccessWatcher] Status changed: ${_lastShares![i]['status']} → ${event[i]['status']}');
            changed = true;
            break;
          }
        }
      }
      
      _lastShares = event;
      
      if (changed) {
        debugPrint('[DeviceAccessWatcher] Event requires access check');
        unawaited(_checkAccess());
      } else {
        debugPrint('[DeviceAccessWatcher] Event identical, skipping');
      }
    },
  );
}
```

---

### Next Step - Backend Team

Hãy kiểm tra:

```sql
-- Backend SQL - What does revoke_share do?
-- 1. Check if DELETE or UPDATE:
SELECT pg_get_functiondef('public.revoke_share'::regprocedure);

-- 2. Check if device_shares table is in Realtime publication:
SELECT * FROM pg_publication WHERE pubname = 'supabase_realtime';

-- 3. Check replica identity for device_shares:
SELECT relreplident FROM pg_class WHERE relname = 'device_shares';
-- Should be 'f' (FULL) for DELETE events to include data
```

---

## Tổng Kết

| Vấn Đề | Dấu Hiệu | Giải Pháp |
|--------|---------|----------|
| Backend không phát DELETE event | Revoke không có event | Backend: Enable REPLICA IDENTITY FULL |
| Event phát nhưng bị skip | Duplicate detection sai | App: Check status change |
| RPC không trigger Realtime | Revoke im lặng | Backend: Explicit pg_notify |
| App không check status change | Event có nhưng bỏ qua | App: Enhance event detection |

**Khuyến Nghị:**
1. ✅ App: Cải thiện event detection (làm ngay)
2. ⚠️ Backend: Kiểm tra RPC + Realtime setup
3. ✅ Both: Confirm thực tế RPC làm gì

---

## Debug Log Mà Chúng Tôi Cần Thấy

Khi **thu hồi lần đầu:**
```
[DeviceAccessWatcher] 🔔 Share change event received: 1 shares  // ← NHƯNG CÓ NHẬN?
[DeviceAccessWatcher] 📋 Share event details: [
  {status: 'revoked', ...}  // ← Status thay đổi từ 'accepted' thành 'revoked'?
]
```

**Nếu:**
- Nhận event + status thay đổi: ✅ Issue ở app detection logic
- Không nhận event: ❌ Issue ở backend/Realtime
- Nhận event + status không thay đổi: ⚠️ RPC logic sai

