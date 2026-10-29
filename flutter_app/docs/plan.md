# Kế hoạch triển khai theo chức năng

Tham chiếu: [requirement.md](requirement.md). Theo dõi tiến độ tại [pipeline.md](pipeline.md).

## Hiện trạng

- Đã có UI prototype (Flutter, dữ liệu demo) cho: login, register, đổi mật khẩu, BLE scan, Wi-Fi config, provision success, device list, dashboard, sensor capacity/config, load control, diagnostics, tech log, console, settings (xem `lib/screens/`).
- MQTT service đã có: kết nối theo phiên đăng nhập, subscribe theo device đã provision, reconnect/resubscribe, publish QoS 1 và route bản tin theo device. Chưa có broker thật để kiểm thử end-to-end.
- Còn thiếu: state store/dashboard realtime hoàn chỉnh và test tích hợp firmware/broker. `LoadController` vẫn đang hard-code 4 tải demo.
- Chưa có kiến trúc layer theo requirement (§2).

## Kiến trúc thư mục đề xuất

```
lib/
  core/            # constants (topic, endpoint), utils, logger (mask password)
  models/          # DeviceSnapshot, SensorData, LoadState, SysStatus, Capabilities, ErrorMask, Ack
  protocol/        # json_mapper (parse/serialize), topic_builder, error_decoder
  services/        # ble_prov_service, mqtt_service, device_session_manager
  state/           # device_state_store, traffic_log_store
  screens/ widgets/ theme/ navigation/   # đã có
test/              # unit test cho protocol + state
```

Gợi ý package (cần spike xác nhận trước khi chốt): `mqtt_client`, thư viện BLE (`flutter_reactive_ble` / `flutter_blue_plus`) + Protocomm Sec1 client (kiểm tra package ESP provisioning có sẵn hoặc tự cài), `uuid`, state management (`provider` hoặc `flutter_riverpod`), `shared_preferences`/`sqflite`, `fl_chart`.

## Các chức năng (feature) và thứ tự thực hiện

Mỗi feature kết thúc khi các tiêu chí "Done" đạt và test tương ứng pass.

### F00 – Nền tảng & quyết định contract
- Chốt Q1–Q9 (requirement §20) với firmware; ghi kết quả vào requirement.md.
- Thêm dependencies, tạo cấu trúc thư mục, cấu hình lint, logger che password.
- Done: `flutter analyze` sạch; cấu trúc thư mục đã tạo.

### F01 – Protocol models & JSON mapper (REQ-040..042, REQ-070, M-04, M-10)
- Models: `Capabilities`, `RuntimeInterfaces`, `SensorData`, `LoadState`, `SysStatus`, `NetInterface`, `DeviceState`.
- Serialize: `prov-config`, `sensor-config`, `load-ctrl`; parse: `sys-status`.
- Validate: slave_id 1–247, name ≤ 32, ssid ≤ 32, pass ≤ 64, sensor_type ∈ {sht40, do, ph}.
- `TopicBuilder` đúng 5 topic.
- Done: unit test round-trip JSON mẫu trong spec; payload không có field ngoài contract.

### F02 – Error decoder & severity (REQ-050, M-06)
- Decode `code_mask` → danh sách `SysError` + severity (warning/critical).
- Done: unit test từng bit và tổ hợp bit.

### F03 – BLE Provisioning (REQ-030..032, REQ-120, M-01)
- Scan service UUID, connect Protocomm Sec1; gửi đúng bốn field `ssid`, `password`, `user_id`, `only_use_ethernet`; poll `prov-status` đến trạng thái cuối (`SUCCESS`/`WARNING`/`ERROR`).
- Dùng `device_id` STA MAC và `saved` từ kết quả cuối; giới hạn chờ 90 giây.
- Quét Wi-Fi bằng JSON mã hóa qua endpoint `wifi-scan` UUID `0xFF54`; không dùng protobuf `prov-scan`.
- Nối vào `ble_scan_screen`, `wifi_config_screen`, `provision_success_screen`; xử lý timeout/lỗi.
- Done: provisioning thật thành công trên thiết bị; Wi-Fi scan `wifi-scan` được xác minh phần cứng; không log password.

### F04 – MQTT Service (REQ-020, REQ-100..104, M-05)
- Khi mở app sau đăng nhập, tạo một MQTT connection với Client ID riêng của installation; thiết bị mới chỉ bổ sung subscription trên connection đó.
- Lưu device ID đã provision để subscribe lại sau lần khởi động app; reconnect tự phục hồi subscriptions.
- Subscribe `telemetry/ack/status`, publish `commands/config/set` QoS 1; chỉ dùng 5 topic theo `requirement.md` §4.
- Done: test với broker mock/thật; hiện đã có unit test topic/router, cần kiểm thử end-to-end với broker/firmware.

### F05 – Device Session Manager & State Store (§2, §8, M-07)
- Device đang chọn, connection state, mapping `DeviceState` ESP32 → UX state, availability từ `status`.
- Lưu danh sách device local; snapshot sensor/load/network/error.
- Done: failover ETH↔Wi-Fi chỉ đổi interface, không đánh dấu sensor lỗi.

### F06 – Device List & Add Device (§11 Device List/Add Device)
- Thay dữ liệu mock bằng store; card hiển thị trạng thái thật; nút Add Device → luồng F03.
- Done: danh sách phản ánh trạng thái từ store.

### F07 – Dynamic Capability UI (REQ-010..014)
- Render danh sách sensor/tải theo `capabilities` + `runtime_interfaces`; đúng 1 ô "Add Sensor" khi còn cổng; ẩn khi đầy.
- Nối `sensor_capacity_screen`.
- Done: widget test các trường hợp 0/3/4 trên 4 cổng.

### F08 – Dashboard realtime (REQ-060..064, M-04)
- Header, network card, sensor grid (valid/invalid), actuator card, alert panel từ `sys-status`/telemetry.
- Telemetry mapper chờ Q5; tạm dùng `sys-status`.
- Done: invalid sensor hiển thị lỗi cục bộ; device vẫn online.

### F09 – Sensor Configuration (REQ-090, REQ-091, M-02)
- Form selector/slave id/name/enabled/offset; validate; publish `config/set`; Pending → ACK/timeout.
- Done: payload đúng contract; UI phản ánh ACK.

### F10 – Load Control (REQ-033..036, REQ-080..085, M-03, M-08)
- `cmd_id` UUID, SET_STATE, duration + countdown, đổi tên `new_name`, Pending/ACK/timeout.
- Hiển thị safety shutdown, không tự bật lại; chỉ load 1 (tuỳ Q4).
- Refactor `LoadController` bỏ dữ liệu demo 4 tải.
- Done: M-03, M-08 pass.

### F11 – Alerts & Diagnostics (REQ-064, §9, M-06)
- Alert panel + diagnostics screen: error list, raw JSON, connection state.
- Done: severity màu đúng theo bảng lỗi.

### F12 – Developer Mode & Console (REQ-110..113, M-09)
- 10 lần chạm App Version bật Developer Mode; traffic log store (timestamp, RX/TX, BLE/MQTT, topic/endpoint); filter Telemetry/Command/ACK/Config/Status; mask password.
- Nối `console_screen`, `tech_log_screen`.
- Done: console hiển thị raw JSON, không lộ password.

### F13 – Historical chart (REQ-065, REQ-072, REQ-073) – có điều kiện
- Lưu telemetry local (hoặc backend nếu có contract) và vẽ chart giờ/ngày/tuần/tháng.
- Phụ thuộc Q5. Làm sau cùng.

### F14 – Account / Auth (REQ-006, REQ-123) – BLOCKED
- Login/Register/Đổi mật khẩu chỉ giữ ở dạng demo/stub; `user_id` cần nguồn (Q7). Không làm backend khi chưa có contract.

### F15 – Security hardening (§17)
- Rà soát log password, TLS theo cấu hình firmware, lưu credential an toàn (`flutter_secure_storage`).
- Done: không có plaintext password trong log/console.

### F16 – Kiểm thử & nghiệm thu (§18)
- Unit/widget test, test tích hợp trên thiết bị thật; checklist M-01…M-10.
- Done: toàn bộ M-xx pass.

## Phụ thuộc

```
F00 -> F01 -> F02
F01 -> F03, F04
F04 + F05 -> F06, F07, F08
F08 -> F09, F10, F11
F04 -> F12
F08 -> F13
F03..F13 -> F15 -> F16
```
