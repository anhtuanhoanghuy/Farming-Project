# Fix: Share Revoke & Ownership Transfer Auto Pop

## Vấn đề
Khi app chủ sở hữu:
1. Thu hồi chia sẻ (revoke share)
2. Chuyển quyền sở hữu (ownership transfer)

App khách vẫn có thể xem và điều khiển thiết bị. Hơn nữa, nếu khách đã vào trang con (cấu hình cảm biến, tải, chẩn đoán, v.v.), khách không tự động bị pop ra.

## Giải pháp
Tạo một global `DeviceAccessWatcher` service để:
1. Listen realtime changes trên `device_shares` table (share revoke)
2. Listen realtime changes trên `devices` table (ownership transfer)
3. Phát broadcast event khi device bị revoke/transfer
4. Các screens lắng nghe events và tự động pop

## Thay đổi

### 1. Thêm `CrudApi.deviceChanges()` stream
**File:** `lib/services/crud_api.dart`

```dart
static Stream<List<Map<String, dynamic>>> deviceChanges(String userId) => _db
    .from('devices')
    .stream(primaryKey: ['id'])
    .eq('user_id', userId);
```

Lắng nghe realtime changes trên bảng `devices` của user (phát hiện ownership transfer).

### 2. Tạo `DeviceAccessWatcher` service
**File:** `lib/services/device_access_watcher.dart` (mới)

- Singleton service lắng nghe cả `shareChanges` và `deviceChanges` streams
- Khi có thay đổi, kiểm tra device access và phát broadcast event `revoked` cho devices bị mất quyền
- Tránh duplicate checking bằng cách seed streams trên lần đầu

```dart
Stream<String> get revoked => _revoked.stream;
// Emits MAC addresses của devices bị revoke/transfer
```

### 3. Update `ShareRevokeListener`
**File:** `lib/widgets/share_revoke_detector.dart`

Thay vì check manually, giờ lắng nghe global `DeviceAccessWatcher.instance.revoked` stream.

```dart
_subscription = DeviceAccessWatcher.instance.revoked.listen(
  (revokedDeviceId) {
    if (revokedDeviceId == deviceId) {
      _onRevoked();
    }
  },
);
```

Khi device bị revoke:
- Hiển thị SnackBar
- Pop tất cả screens về device list bằng `popUntil((route) => route.isFirst)`

### 4. Khởi tạo `DeviceAccessWatcher` ở app startup
**File:** `lib/screens/splash_screen.dart`

```dart
if (signedIn) {
  DeviceAccessWatcher.instance.start();
}
```

## Cách hoạt động

### Share Revoke
1. Chủ sở hữu thu hồi chia sẻ (xóa row từ `device_shares`)
2. `DeviceAccessWatcher` nhận event từ `shareChanges` stream
3. Kiểm tra `listSharedDevices()` - device không còn ở đó
4. Phát broadcast: `revoked.add(macAddress)`
5. `ShareRevokeListener` ở khách nhận được event
6. Pop screen, hiển thị SnackBar

### Ownership Transfer
1. Chủ sở hữu chuyển quyền (update `devices.user_id`)
2. `DeviceAccessWatcher` nhận event từ `deviceChanges` stream
3. Kiểm tra `listDevices()` - device không còn ở đó (user_id đã thay đổi)
4. Phát broadcast: `revoked.add(macAddress)`
5. `ShareRevokeListener` ở khách nhận được event
6. Pop tất cả screens, hiển thị SnackBar

## Screens được bảo vệ
- `DashboardScreen` ✓
- `SensorCapacityScreen` ✓
- `SensorConfigScreen` ✓
- `LoadControlScreen` ✓
- `DiagnosticsScreen` ✓

Tất cả đều dùng `ShareRevokeListener` và tự động pop khi device bị revoke/transfer.

## Edge cases
- ✓ Multiple screens mở cùng lúc: Pop hết bằng `popUntil((route) => route.isFirst)`
- ✓ Stream seed: Bỏ qua first event (snapshot), chỉ xử lý changes
- ✓ Offline mode: Nếu không kết nối, không phát hiện được (nhưng khi quay lại online, sẽ refresh)
- ✓ Context safety: Kiểm tra `context.mounted` trước khi pop

## Testing
Để test, cần:
1. 2 devices (chủ + khách)
2. Chủ chia sẻ, khách chấp nhận
3. Khách vào trang con (dashboard -> sensor config)
4. Chủ:
   - Option A: Thu hồi chia sẻ (delete từ device_shares)
   - Option B: Chuyển quyền (update devices.user_id)
5. Kỳ vọng: Khách bị pop hết về device list + thấy SnackBar
