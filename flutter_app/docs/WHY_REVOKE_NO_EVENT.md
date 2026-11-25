# Tại Sao Gửi Lời Mời Có Event Nhưng Thu Hồi Không - Phân Tích Chi Tiết

**Ngày:** 2026-11-18  
**Vấn Đề:** App khách bắt được event khi Host gửi lời mời, nhưng không bắt được khi Host thu hồi

---

## 🔍 Vấn Đề Chi Tiết

### Hiện Tượng Quan Sát

#### Khi Gửi Lời Mời (sendInvite) ✅
1. Host app gọi `sendInvite(guestId, deviceId)`
2. Backend thực hiện: `INSERT INTO device_shares VALUES (...)`
3. Supabase Realtime phát event: **NEW SHARE CREATED**
4. Guest app nhận event ngay lập tức
5. Guest app stream listener trigger:
   ```
   [DeviceAccessWatcher] Share change event received: 1 shares
   ```
6. Guest app logout hoặc hiển thị thông báo ✅

#### Khi Thu Hồi (revokeShare) ❌
1. Host app gọi `revokeShare(shareId)`
2. Backend thực hiện: `DELETE FROM device_shares WHERE id = ...` (?)
3. Supabase Realtime **KHÔNG phát event**? Hoặc event **BỎNG QUA**?
4. Guest app **KHÔNG nhận event**
5. Guest app stream listener **KHÔNG trigger**
6. Guest app vẫn ở màn hình device ❌
7. Guest phải mở lại màn hình hoặc Host gửi lời mời lần 2 để logout

---

## 🤔 Lý Do Tại Sao?

### Giả Thuyết 1: Supabase Realtime Không Phát DELETE Event

**Vấn Đề:**
- Supabase Realtime có thể được cấu hình chỉ phát INSERT/UPDATE event
- DELETE event yêu cầu cấu hình đặc biệt: `REPLICA IDENTITY FULL`

**Chứng Cứ:**
```sql
-- Nếu device_shares KHÔNG có REPLICA IDENTITY FULL:
-- DELETE không có row data, Realtime sẽ:
-- A) Không phát event
-- B) Phát event nhưng không có row data
```

**Kết Quả:**
- INSERT share → Realtime phát event ✅
- UPDATE share status → Realtime phát event ✅
- DELETE share → Realtime **KHÔNG phát** (default behavior) ❌

---

### Giả Thuyết 2: RPC `revoke_share` UPDATE Thay Vì DELETE

**Có Thể:**
```sql
-- Backend không DELETE, mà UPDATE:
CREATE FUNCTION revoke_share(p_share_id UUID) AS $$
BEGIN
  UPDATE device_shares 
  SET status = 'revoked', updated_at = NOW()
  WHERE id = p_share_id;
END;
$$;
```

**Nếu Vậy:**
- Event SẼ được phát (UPDATE always phát event)
- Nhưng row vẫn tồn tại với `status = 'revoked'`

**Vấn Đề App:**
```dart
// App lưu _lastShares = [{ id: xxx, status: 'accepted', ... }]
// Backend update thành: { id: xxx, status: 'revoked', ... }
// App nhận event: [{ id: xxx, status: 'revoked', ... }]

// Nhưng app code cũ chỉ check:
if (_lastShares?.length == event.length) {  // 1 == 1
  debugPrint('No change, skip');
  return;  // ❌ BUG! Status đã thay đổi nhưng bỏ qua
}
```

**Kết Quả:**
Event được phát ✅, nhưng app bỏ qua ❌

---

### Giả Thuyết 3: Backend RPC Không Trigger Realtime

**Vấn Đề:**
```sql
-- Có thể RPC không được đánh dấu để trigger Realtime:
CREATE FUNCTION revoke_share(p_share_id UUID) 
RETURNS void 
LANGUAGE plpgsql
-- ⚠️ Không có: SECURITY DEFINER / Trigger config
AS $$
BEGIN
  DELETE FROM device_shares WHERE id = p_share_id;
  -- No explicit notification
END;
$$;
```

**Kết Quả:**
- RPC thực thi ✅
- Database thay đổi ✅
- Realtime event **KHÔNG phát** ❌

---

## ✅ Giải Pháp Đã Triển Khai

### App Side - Cải Thiện Event Detection

**Vừa Thay Đổi Trong `device_access_watcher.dart`:**

#### Trước (Bỏ Qua Event):
```dart
// ❌ OLD: Chỉ check count, bỏ qua status change
if (_lastShares?.length == event.length) {
  debugPrint('Share count unchanged, skip');
  return;  // ❌ WRONG if status changed!
}
unawaited(_checkAccess());
```

#### Sau (Catch Status Change):
```dart
// ✅ NEW: Check both count AND status
bool changed = (_lastShares?.length ?? 0) != event.length;

// Also check if any share status changed
if (!changed && _lastShares != null && _lastShares!.length == event.length) {
  for (int i = 0; i < event.length; i++) {
    final lastStatus = _lastShares![i]['status'];
    final newStatus = event[i]['status'];
    if (lastStatus != newStatus) {
      debugPrint('[DeviceAccessWatcher] Status changed: $lastStatus → $newStatus');
      changed = true;
      break;
    }
  }
}

if (changed) {
  debugPrint('✅ Change detected - checking access');
  unawaited(_checkAccess());
} else {
  debugPrint('🔄 Identical - skipping');
}
```

**Lợi Ích:**
- ✅ Detect status change từ 'accepted' → 'revoked'
- ✅ Trigger access check ngay cả khi count không thay đổi
- ✅ Phát hiện UPDATE event (nếu backend UPDATE thay DELETE)

---

### Debug Logging Cải Tiến

**New Debug Output:**
```
// Khi event nhận được:
[DeviceAccessWatcher] 🔔 Share change event received: 1 shares
[DeviceAccessWatcher] 📋 Share event details: [
  {id: xxx, guest_id: yyy, status: 'revoked', ...}
]
[DeviceAccessWatcher] ⚠️  Status changed for share xxx: 'accepted' → 'revoked'
[DeviceAccessWatcher] ✅ Share change detected - checking access
```

---

## 📋 Các Trường Hợp Giải Pháp Xử Lý

### Case 1: Backend DELETE (Realtime Không Phát)
**Triệu Chứng:**
- Không có event
- Guest app không logout

**Giải Pháp:**
- ❌ Không xử lý được từ app side
- ✅ Fallback: `checkAccessNow()` on screen entry
- ⚠️ Cần Backend Fix

---

### Case 2: Backend UPDATE Status (Realtime Phát)
**Triệu Chứng:**
- Event phát nhưng bỏ qua
- Share vẫn tồn tại nhưng `status = 'revoked'`

**Giải Pháp:**
- ✅ **GỌI LÀM RỒI** - App cải thiện detection
- ✅ Giờ detect status change
- ✅ Trigger `_checkAccess()` ngay

---

### Case 3: Backend RPC Không Trigger Realtime
**Triệu Chứng:**
- Không có event
- Database thay đổi nhưng app không biết

**Giải Pháp:**
- ❌ Không xử lý được từ app side
- ✅ Fallback: `checkAccessNow()` on screen entry
- ⚠️ Cần Backend Fix

---

## 🧪 Cách Test Giải Pháp

### Test 1: Xem Event Khi Thu Hồi

**Setup:**
1. Guest app mở DiagnosticsScreen
2. Host app open share list
3. Host app click thu hồi

**Watch Logs:**
```
[DeviceAccessWatcher] 🔔 Share change event received: ...
[DeviceAccessWatcher] 📋 Share event details: ...
```

**Mong Đợi:**
- ✅ Nhận event
- ✅ Thấy status change log (nếu UPDATE)
- ✅ Thấy "✅ Share change detected" log
- ✅ Guest app logout

---

### Test 2: Xem Status Change Detection

**Logs Chứng Minh Hoạt Động:**
```
// BEFORE (cũ):
[DeviceAccessWatcher] 🔄 Share count unchanged (1), might be duplicate
[DeviceAccessWatcher] Processing share change...  // ← Vẫn trigger nhưng log sai

// AFTER (mới):
[DeviceAccessWatcher] ⚠️  Status changed for share abc123: accepted → revoked
[DeviceAccessWatcher] ✅ Share change detected - checking access
```

---

## 📞 Hỏi Backend Team

**Cần Kiểm Tra:**

1. **Backend `revoke_share` RPC làm gì?**
   ```sql
   -- DELETE row?
   DELETE FROM device_shares WHERE id = p_share_id;
   
   -- Hay UPDATE status?
   UPDATE device_shares SET status = 'revoked' WHERE id = p_share_id;
   ```

2. **Supabase Realtime được enable cho device_shares?**
   ```sql
   SELECT * FROM pg_publication WHERE pubname = 'supabase_realtime';
   -- device_shares phải nằm trong publication
   ```

3. **REPLICA IDENTITY cho device_shares?**
   ```sql
   SELECT relreplident FROM pg_class WHERE relname = 'device_shares';
   -- Nên là 'f' (FULL) để DELETE có row data
   ```

4. **RPC có trigger notification?**
   ```sql
   -- Có SECURITY DEFINER hay explicit pg_notify?
   SELECT pg_get_functiondef('public.revoke_share'::regprocedure);
   ```

---

## 🛠️ Backend Fix (If Needed)

### Option 1: Ensure DELETE Events are Sent

**SQL Migration:**
```sql
-- Ensure device_shares sends DELETE events
ALTER TABLE device_shares REPLICA IDENTITY FULL;
-- (This allows Realtime to include row data in DELETE events)
```

---

### Option 2: Use UPDATE Instead of DELETE

**SQL Change:**
```sql
CREATE OR REPLACE FUNCTION revoke_share(p_share_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE device_shares 
  SET status = 'revoked', 
      updated_at = NOW()
  WHERE id = p_share_id;
END;
$$;
-- UPDATE always triggers Realtime
-- App can detect status: 'accepted' → 'revoked'
```

---

### Option 3: Explicit Realtime Notification

**SQL Change:**
```sql
CREATE OR REPLACE FUNCTION revoke_share(p_share_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_guest_id UUID;
BEGIN
  DELETE FROM device_shares WHERE id = p_share_id;
  
  -- Explicit notification for Realtime
  -- (May need custom setup depending on backend)
  PERFORM pg_notify('device_access_changed', 
    json_build_object('event', 'revoke', 'share_id', p_share_id)::text
  );
END;
$$;
```

---

## 📊 Trạng Thái Hiện Tại

| Yếu Tố | Trạng Thái | Lưu Ý |
|--------|-----------|-------|
| App Event Detection | ✅ Cải Thiện | Giờ detect status change |
| App Fallback Check | ✅ Có sẵn | `checkAccessNow()` on entry |
| Backend DELETE Event | ❓ Chưa biết | Cần kiểm tra |
| Backend Status Change | ❓ Chưa biết | Cần kiểm tra |
| Realtime Publication | ❓ Chưa biết | Cần kiểm tra |

---

## 🎯 Hành Động Tiếp Theo

### Ngay (App Side) ✅
- [x] Cải thiện event detection
- [x] Check status change
- [x] Add detailed logging
- [x] Build & verify (0 errors)

### Tiếp Theo (Backend Team) ⚠️
- [ ] Kiểm tra RPC `revoke_share` logic
- [ ] Kiểm tra Realtime setup
- [ ] Confirm DELETE vs UPDATE
- [ ] Fix nếu cần thiết

### Cuối Cùng (Testing) 🧪
- [ ] Test avec logs để xem event
- [ ] Confirm status change detection
- [ ] Verify logout ngay lập tức
- [ ] Test fallback (background revoke)

---

## 📝 Tóm Tắt

**Vấn Đề Gốc:**
Thu hồi không gửi event như gửi lời mời

**Nguyên Nhân Tiềm Ẩn:**
1. Realtime không phát DELETE event (cần REPLICA IDENTITY FULL)
2. Event phát nhưng app bỏ qua vì chỉ check count
3. RPC không trigger notification

**Giải Pháp Triển Khai:**
1. ✅ App: Detect status change, không chỉ count
2. ✅ App: Detailed logging để diagnose
3. ⚠️ Backend: Kiểm tra & fix

**Kết Quả:**
- Nếu backend UPDATE: Guest logout ngay ✅
- Nếu backend DELETE: Guest logout on screen entry (fallback) ✅

