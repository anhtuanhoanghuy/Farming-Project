# Debug Guide - Tìm Ra Tại Sao Thu Hồi Không Có Event

**Mục Đích:** Xác định chính xác lý do tại sao gửi lời mời có event nhưng thu hồi không

---

## 🔧 Setup Debug Environment

### Bước 1: Enable Detailed Logging

**Android:**
```bash
# Terminal 1 - Filter Flutter logs
adb logcat | grep -i "flutter\|DeviceAccessWatcher\|ShareRevokeListener"

# Terminal 2 - Alternative (less powerful filter)
adb logcat | grep -i "DeviceAccessWatcher"
```

**iOS:**
```bash
# Xcode Console
cmd + shift + y
# Search for "DeviceAccessWatcher"
```

---

## 📋 Test Scenario 1: Send Invite (Baseline)

**Mục Đích:** Xem event log khi gửi lời mời (để so sánh)

### Bước Thực Hiện:

1. **Setup:**
   - App Host: Mở
   - App Guest: Mở, logged in, nhưng **KHÔNG xem device**
   - Terminal: Ready để capture logs

2. **Test:**
   - Trên Host app: Click để chia sẻ device
   - Chọn guest user và click "Gửi lời mời"
   - Ngay lập tức nhìn vào logs

3. **Logs Mong Đợi:**
   ```
   I/flutter: [DeviceAccessWatcher] 🔔 Share change event received: 1 shares
   I/flutter: [DeviceAccessWatcher] 📋 Share event details: [
     {id: ..., guest_id: ..., device_id: ..., status: 'pending', ...}
   ]
   I/flutter: [DeviceAccessWatcher] ⚠️  Status changed for share xxx: null → pending
   I/flutter: [DeviceAccessWatcher] ✅ Share change detected - checking access
   I/flutter: [DeviceAccessWatcher] Checking device access...
   I/flutter: [DeviceAccessWatcher] Owned devices from server: X
   I/flutter: [DeviceAccessWatcher] Shared devices from server: Y
   ```

4. **Lưu Ý:**
   - Thời gian delay giữa click và event: **~1-2 giây**
   - Event có chứa full row data: **CÓ** ✅
   - Status: 'pending' or 'accepted'?

**Ghi Lại:**
```
Gửi lời mời:
- Thời gian: ___ giây
- Event received: YES / NO
- Event details: [paste logs here]
- Status giá trị: ___
```

---

## 📋 Test Scenario 2: Revoke Share (Main Test)

**Mục Đích:** Xem event log khi thu hồi (để so sánh với gửi mời)

### Bước Thực Hiện:

1. **Setup:**
   - App Host: Mở share list (device đã được chia sẻ từ scenario 1)
   - App Guest: Mở, nhìn DiagnosticsScreen của device vừa chia sẻ
   - Terminal: Ready để capture logs
   - **Quan trọng:** Để logs chạy cả trước và sau click

2. **Test:**
   - Trên Host app: Tìm guest trong share list
   - Click "Thu hồi" (revoke)
   - **Ngay lập tức** nhìn vào logs Guest app
   - Chú ý: Guest app có logout không?

3. **Logs Mong Đợi (Best Case):**
   ```
   I/flutter: [DeviceAccessWatcher] 🔔 Share change event received: 1 shares
   I/flutter: [DeviceAccessWatcher] 📋 Share event details: [
     {id: ..., guest_id: ..., device_id: ..., status: 'revoked', ...}
   ]
   I/flutter: [DeviceAccessWatcher] ⚠️  Status changed for share xxx: accepted → revoked
   I/flutter: [DeviceAccessWatcher] ✅ Share change detected - checking access
   I/flutter: [DeviceAccessWatcher] Checking device access...
   I/flutter: [DeviceAccessWatcher] ⚠️  DEVICE REVOKED: Tủ điều khiển (84c7bb772310)
   I/flutter: [DeviceAccessWatcher] Emitting revoke for device: 84c7bb772310
   I/flutter: [ShareRevokeListener] Received revoke event for: 84c7bb772310 (listening for: 84c7bb772310)
   I/flutter: [ShareRevokeListener] ⚠️  MATCH! Device revoked: 84c7bb772310
   I/flutter: [ShareRevokeListener] 📱 Executing _onRevoked for 84c7bb772310
   ```

4. **Logs Mong Đợi (Problem Case 1 - No Event):**
   ```
   [DeviceAccessWatcher] Share change event KHÔNG nhận được
   [Guest app vẫn ở DiagnosticsScreen]
   ```

5. **Logs Mong Đợi (Problem Case 2 - Event Bỏ Qua):**
   ```
   I/flutter: [DeviceAccessWatcher] 🔔 Share change event received: 1 shares
   I/flutter: [DeviceAccessWatcher] 📋 Share event details: [
     {id: ..., guest_id: ..., device_id: ..., status: 'revoked', ...}
   ]
   I/flutter: [DeviceAccessWatcher] 🔄 Share event identical, skipping access check
   [Guest app vẫn ở DiagnosticsScreen - LỖI!]
   ```

**Ghi Lại:**
```
Thu Hồi:
- Thời gian: ___ giây (so sánh với gửi mời)
- Event received: YES / NO
- Event details: [paste logs here]
- Status thay đổi: ___ → ___
- Guest logout: YES / NO
- Logs nếu không logout: [paste]
```

---

## 🔍 Analysis Logs

### Dấu Hiệu 1: Không Nhận Event

**Logs:**
```
[No share change event received]
[Guest app vẫn ở screen đó]
```

**Kết Luận:**
- ❌ Backend không phát event
- **Nguyên Nhân:** Realtime không detect DELETE, hoặc RPC không trigger

**Giải Pháp:**
- ⚠️ Cần Backend Fix
- ✅ App đã có fallback: `checkAccessNow()` on screen entry

---

### Dấu Hiệu 2: Event Nhận Nhưng Status Không Thay Đổi

**Logs:**
```
[DeviceAccessWatcher] 🔔 Share change event received: 1 shares
[DeviceAccessWatcher] 📋 Share event details: [
  {id: ..., status: 'accepted', ...}  ← Status vẫn 'accepted'?!
]
```

**Kết Luận:**
- ⚠️ Backend không update status
- **Nguyên Nhân:** Backend DELETE thay UPDATE, event có nhưng row bị xóa, event data empty

**Giải Pháp:**
- ⚠️ Cần Backend Fix
- ✅ App đã có fallback: Nếu list length = 0, là revoke

---

### Dấu Hiệu 3: Status Thay Đổi Nhưng Bỏ Qua (CŨ CODE)

**Logs (Cũ):**
```
[DeviceAccessWatcher] 🔄 Share count unchanged (1), might be duplicate
[DeviceAccessWatcher] Processing share change...  ← Vẫn trigger nhưng logic sai
```

**Kết Luận:**
- ✅ Event phát
- ✅ Status thay đổi
- ❌ Code cũ bỏ qua event

**Giải Pháp:**
- ✅ **GỌI LÀM RỒI** - Cập nhật code để detect status change

**Logs (Mới):**
```
[DeviceAccessWatcher] ⚠️  Status changed for share xxx: accepted → revoked
[DeviceAccessWatcher] ✅ Share change detected - checking access
```

---

### Dấu Hiệu 4: Empty Event (DELETE Case)

**Logs:**
```
[DeviceAccessWatcher] 🔔 Share change event received: 0 shares
[DeviceAccessWatcher] 📋 Share event details: []
```

**Kết Luận:**
- ✅ Event phát (empty list = row deleted)
- ✅ App nhận được

**Giải Pháp:**
- ✅ Code check `_lastShares?.length != event.length` → Trigger access check
- ✅ Nên hoạt động ngay

---

## 🧪 Test Scenario 3: Revoke While Background

**Mục Đích:** Test fallback mechanism

### Bước Thực Hiện:

1. **Setup:**
   - App Guest: Logged in, DiagnosticsScreen loaded, then
     - **Nhấn home button hoặc switch app** (app to background)
   - App Host: Ready để click revoke
   - Logs running (device connected)

2. **Test:**
   - App Guest in background
   - App Host: Click revoke
   - **Chờ 10 giây** (logs không phát signal)
   - App Guest: Return to app
   - App Guest: Navigate back to DiagnosticsScreen

3. **Logs Mong Đợi:**
   ```
   // Khi Guest return và navigate to screen:
   I/flutter: [DiagnosticsScreen] Checking access on entry for device: 84c7bb772310
   I/flutter: [DeviceAccessWatcher] Checking device access...
   I/flutter: [DeviceAccessWatcher] ⚠️  DEVICE REVOKED: Tủ điều khiển (84c7bb772310)
   I/flutter: [DeviceAccessWatcher] Emitting revoke for device: 84c7bb772310
   I/flutter: [ShareRevokeListener] MATCH! Device revoked: 84c7bb772310
   I/flutter: [ShareRevokeListener] 📱 Executing _onRevoked for 84c7bb772310
   ```

4. **Result:**
   - ✅ Screen immediately closes (fallback works)
   - ✅ Snackbar shows "Quyền truy cập thiết bị đã bị thu hồi"

---

## 📊 Comparison Table

Tạo bảng để so sánh Gửi Mời vs Thu Hồi:

| Yếu Tố | Gửi Mời | Thu Hồi |
|--------|---------|--------|
| Event phát? | ✅ YES | ??? |
| Thời gian delay | ___ sec | ___ sec |
| Event data | {status: pending} | {status: revoked} hoặc [] |
| Status change detected? | ✅ null→pending | ??? |
| Logout ngay? | ❓ | ??? |
| Logs output | [paste] | [paste] |

---

## 🎯 Diagnosis Decision Tree

```
              Revoke Click trên Host
                       │
                       ▼
        Has event received? (logs show event?)
              ╱                    ╲
            YES                    NO
             │                      │
             ▼                      ▼
     Event data chứa gì?    Backend không phát
             │              (Realtime disable?)
       ╱─────┴─────╲
      │             │
    empty[]      status: revoked
      │             │
      ▼             ▼
    DELETE       UPDATE
      │             │
      ▼             ▼
  Count: 0→1   Status changed
  Trigger      Logs show
  ✅ WORKS    "Status changed"?
                   │
              ╱────┴────╲
            YES          NO
             │            │
             ▼            ▼
    ✅ WORKS    ❌ CODE BUG
            (cũ bỏ qua)
```

---

## 📝 Logging Checklist

Khi test, ghi lại:

- [ ] Gửi mời event received: Y/N, thời gian: ___ sec
- [ ] Thu hồi event received: Y/N, thời gian: ___ sec
- [ ] Status change log visible: Y/N
- [ ] Guest logout ngay: Y/N
- [ ] Fallback (background) work: Y/N
- [ ] Exact logs: [attached file name]

---

## 🚀 Next Steps

**Sau khi gather logs:**

1. Share logs file: **Attach từ adb logcat**
2. Điền diagnosis form trên
3. I sẽ analyze:
   - Confirm nguyên nhân
   - Recommend backend fix nếu cần
   - Verify app side fix hoạt động

---

## 💡 Tips

**Capture Full Logs:**
```bash
# Android - Save to file
adb logcat > revoke_test.log

# Kill app, restart, do test, then
# Grep for DeviceAccessWatcher
grep "DeviceAccessWatcher\|ShareRevokeListener" revoke_test.log
```

**iOS:**
1. Xcode → Product → Scheme → Edit Scheme
2. Run → Pre-actions → Add script
3. Or just copy from Console

**Common Mistakes:**
- ❌ Logs don't show because filter is wrong
- ❌ App not logged in
- ❌ Device not shared properly
- ❌ Logs truncated (save to file)

