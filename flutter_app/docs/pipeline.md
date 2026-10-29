# Pipeline – Tiến độ triển khai

Nguồn sự thật duy nhất cho tiến độ. Chi tiết feature: [plan.md](plan.md); yêu cầu: [requirement.md](requirement.md).

**Cập nhật lần cuối:** 2026-10-16

## Quy ước

- Trạng thái: `TODO` · `IN_PROGRESS` · `BLOCKED` · `DONE`.
- Mỗi lần bắt đầu/kết thúc task: sửa cột **Status**, **Owner**, **Updated** và dòng "Cập nhật lần cuối".
- Task chỉ `DONE` khi đạt tiêu chí "Done" trong plan.md và `flutter analyze` + `flutter test` pass.
- Task bị chặn bởi câu hỏi contract (requirement.md §20) → `BLOCKED` và ghi mã `Q#` ở cột Notes.
- Mỗi PR/commit nên ghi ID task (ví dụ `F04-2`).

## Tổng quan

| Feature | Tên | Status | Tiến độ | Phụ thuộc | Acceptance |
|---|---|---|---|---|---|
| F00 | Nền tảng & chốt contract | TODO | 0/4 | – | – |
| F01 | Protocol models & JSON mapper | TODO | 0/5 | F00 | M-04, M-10 |
| F02 | Error decoder & severity | TODO | 0/2 | F01 | M-06 |
| F03 | BLE Provisioning | IN_PROGRESS | 4/4 | F01 | M-01 |
| F04 | MQTT Service | IN_PROGRESS | 4/4 | F01 | M-05 |
| F05 | Device Session Manager & State Store | TODO | 0/4 | F04 | M-07 |
| F06 | Device List & Add Device | TODO | 0/3 | F03, F05 | – |
| F07 | Dynamic Capability UI | TODO | 0/3 | F05 | – |
| F08 | Dashboard realtime | TODO | 0/5 | F05 | M-04 |
| F09 | Sensor Configuration | TODO | 0/4 | F08 | M-02 |
| F10 | Load Control | TODO | 0/5 | F08 | M-03, M-08 |
| F11 | Alerts & Diagnostics | TODO | 0/3 | F02, F08 | M-06 |
| F12 | Developer Mode & Console | TODO | 0/4 | F04 | M-09 |
| F13 | Historical chart | BLOCKED | 0/3 | F08 | Q5 |
| F14 | Account / Auth | BLOCKED | 0/1 | – | Q7 |
| F15 | Security hardening | TODO | 0/3 | F03–F13 | – |
| F16 | Kiểm thử & nghiệm thu | TODO | 0/3 | F15 | M-01…M-10 |

## Baseline đã có (UI prototype, dữ liệu demo)

| ID | Hạng mục | Status | Notes |
|---|---|---|---|
| P-01 | UI screens: login, register, change password, ble scan, wifi config, provision success | DONE | `lib/screens/`, chỉ UI |
| P-02 | UI screens: device list, dashboard, sensor capacity/config, load control | DONE | Dùng mock; `LoadController` hard-code 4 tải |
| P-03 | UI screens: diagnostics, tech log, console, settings | DONE | Mock |
| P-04 | Theme + widget dùng chung + routing + bottom nav | DONE | `lib/theme`, `lib/widgets`, `lib/navigation` |

## Chi tiết task

| ID | Feature | Task | Status | Owner | Updated | Notes |
|---|---|---|---|---|---|---|
| F00-1 | F00 | Chốt Q1–Q9 với firmware, cập nhật requirement.md | TODO | | | Q1–Q9 |
| F00-2 | F00 | Thêm dependencies (mqtt, BLE, uuid, state mgmt, storage, chart) | IN_PROGRESS | | 2026-10-07 | Đã thêm `flutter_blue_plus`; cần spike Protocomm Sec1 |
| F00-3 | F00 | Tạo cấu trúc `core/ models/ protocol/ services/ state/` | TODO | | | |
| F00-4 | F00 | Logger che password | TODO | | | REQ-113 |
| F01-1 | F01 | Models: Capabilities, RuntimeInterfaces, SensorData, LoadState, SysStatus, NetInterface | TODO | | | |
| F01-2 | F01 | Serialize `prov-config`, `sensor-config`, `load-ctrl` | TODO | | | |
| F01-3 | F01 | Parse `sys-status` | TODO | | | |
| F01-4 | F01 | Validator (slave_id, độ dài name/ssid/pass, sensor_type) | TODO | | | REQ-090..092 |
| F01-5 | F01 | `TopicBuilder` 5 topic + unit test contract | TODO | | | Q1 |
| F02-1 | F02 | Decode `code_mask` → `SysError` + severity | TODO | | | Q9 |
| F02-2 | F02 | Unit test từng bit/tổ hợp | TODO | | | |
| F03-1 | F03 | Scan theo Service UUID `021a9004-0382-4aea-bff4-6b3f1c5adfb4` (REQ-032a) | DONE | | 2026-10-07 | Chỉ lọc theo UUID, không lọc theo tên; `BleScanController`; cần test thiết bị thật |
| F03-2 | F03 | Kết nối Protocomm Sec1 | DONE | | 2026-10-07 | `ProtocommSession`; chưa test thiết bị thật; Q2, Q10 |
| F03-3 | F03 | Gửi đúng bốn field `prov-config`; poll `prov-status` và xử lý kết quả/timeout | DONE | Copilot | 2026-10-12 | Dùng `device_id` STA MAC; phân biệt SUCCESS/WARNING/ERROR; cần test thiết bị thật |
| F03-4 | F03 | Nối `ble_scan_screen`, `wifi_config_screen`, `provision_success_screen` | IN_PROGRESS | | 2026-10-12 | Truyền device ID/kết quả thật và Ethernet fallback; chờ kiểm thử trên thiết bị thật |
| F04-1 | F04 | Kết nối broker + reconnect + resubscribe | DONE | Copilot | 2026-10-12 | Cấu hình `--dart-define`; Client ID riêng của app; cần verify broker thật |
| F04-2 | F04 | Subscribe `telemetry`, `ack`, `status` | DONE | Copilot | 2026-10-12 | Kết nối sau login; subscribe lại device đã lưu và thiết bị mới provision |
| F04-3 | F04 | Publish `commands`, `set` QoS 1 | DONE | Copilot | 2026-10-12 | API transport đã có; tích hợp UI/ACK chờ contract Q6 |
| F04-4 | F04 | Router message theo `device_id` | DONE | Copilot | 2026-10-12 | Router theo namespace/user/device; unit test |
| F05-1 | F05 | Device Session Manager (device đang chọn, connection state) | TODO | | | |
| F05-2 | F05 | Map `STATE_*` → UX state | TODO | | | §8 |
| F05-3 | F05 | Device State Store (snapshot) + lưu device local | TODO | | | |
| F05-4 | F05 | Availability từ `status`; failover ≠ sensor failure | TODO | | | Q8 |
| F06-1 | F06 | Device List từ store | TODO | | | |
| F06-2 | F06 | Add Device → luồng BLE | TODO | | | |
| F06-3 | F06 | Trạng thái card thật (online/offline/interface) | TODO | | | |
| F07-1 | F07 | Parse capabilities/runtime_interfaces | TODO | | | |
| F07-2 | F07 | Render động sensor/load/4-20mA, 1 ô Add Sensor | TODO | | | REQ-012/013 |
| F07-3 | F07 | Widget test các trường hợp 0/3/4 trên 4 cổng | TODO | | | |
| F08-1 | F08 | Header + network card | TODO | | | |
| F08-2 | F08 | Sensor grid SHT40/DO/pH | TODO | | | |
| F08-3 | F08 | Xử lý `valid=false` cục bộ | TODO | | | REQ-040 |
| F08-4 | F08 | Actuator card + alert panel | TODO | | | |
| F08-5 | F08 | Telemetry mapper (đúng schema firmware) | BLOCKED | | | Q5 |
| F09-1 | F09 | Form sensor + validate | TODO | | | |
| F09-2 | F09 | Publish `sensor-config` qua `set` | TODO | | | |
| F09-3 | F09 | Pending/ACK/timeout | TODO | | | Q6 |
| F09-4 | F09 | Test M-02 trên thiết bị | TODO | | | |
| F10-1 | F10 | Gỡ dữ liệu demo `LoadController` | TODO | | | Q4 |
| F10-2 | F10 | `SET_STATE` + `cmd_id` UUID + duration + countdown | TODO | | | |
| F10-3 | F10 | Rename tải (`new_name`) | TODO | | | |
| F10-4 | F10 | Pending/ACK/timeout | TODO | | | Q6 |
| F10-5 | F10 | Safety shutdown: cảnh báo, không tự bật lại | TODO | | | M-08 |
| F10-6 | F10 | Cảnh báo thứ tự ưu tiên trước khi thêm điều kiện/lịch; hủy không publish, xác nhận mới publish | DONE | Copilot | 2026-10-16 | Popup giải thích hẹn giờ trễ > điều kiện > lịch; firmware vẫn là nguồn sự thật |
| F11-1 | F11 | System alert panel | TODO | | | |
| F11-2 | F11 | Diagnostics screen: error list, raw JSON, connection state | TODO | | | |
| F11-3 | F11 | Màu severity theo bảng lỗi | TODO | | | |
| F12-1 | F12 | Traffic log store (timestamp, RX/TX, BLE/MQTT, topic) | TODO | | | |
| F12-2 | F12 | 10 lần chạm App Version bật Developer Mode | TODO | | | |
| F12-3 | F12 | Console + filter + mask password | TODO | | | |
| F12-4 | F12 | Nối `console_screen`, `tech_log_screen` | TODO | | | |
| F13-1 | F13 | Lưu telemetry local | BLOCKED | | | Q5 |
| F13-2 | F13 | Chart giờ/ngày/tuần/tháng | BLOCKED | | | Q5 |
| F13-3 | F13 | Chart trong dashboard | BLOCKED | | | Q5 |
| F14-1 | F14 | Giữ Login/Register/Đổi mật khẩu ở dạng stub; chốt nguồn `user_id` | BLOCKED | | | Q7 |
| F15-1 | F15 | Rà soát log/console không lộ password | TODO | | | |
| F15-2 | F15 | Lưu credential an toàn | TODO | | | |
| F15-3 | F15 | MQTT TLS theo cấu hình firmware | TODO | | | REQ-122 |
| F16-1 | F16 | Unit + widget test toàn bộ | TODO | | | |
| F16-2 | F16 | Test tích hợp thiết bị thật M-01…M-10 | TODO | | | |
| F16-3 | F16 | Báo cáo nghiệm thu | TODO | | | |

## Acceptance checklist

| ID | Test | Status | Feature |
|---|---|---|---|
| M-01 | BLE Provisioning | TODO | F03 |
| M-02 | Sensor Config | TODO | F09 |
| M-03 | Load Control | TODO | F10 |
| M-04 | System Status | TODO | F01, F08 |
| M-05 | MQTT Topics | DONE | F04 |
| M-06 | Error Decode | TODO | F02, F11 |
| M-07 | Failover UI | TODO | F05 |
| M-08 | Safety Interlock | TODO | F10 |
| M-09 | Developer Mode | TODO | F12 |
| M-10 | Contract Integrity | TODO | F01 |

## Open questions (chặn tiến độ)

Xem chi tiết tại requirement.md §20 (Q1–Q9). Cập nhật cột "Resolved" khi chốt.

| Q | Resolved | Quyết định |
|---|---|---|
| Q1 | No | |
| Q2 | No | |
| Q3 | No | |
| Q4 | No | |
| Q5 | No | |
| Q6 | No | |
| Q7 | No | |
| Q8 | No | |
| Q9 | No | |
| Q10 | No | |
| Q11 | No | |
| Q12 | No | |

## Nhật ký

| Ngày | Thay đổi |
|---|---|
| 2026-10-07 | Khởi tạo requirement, plan, pipeline từ `Mobile_requirement.docx` |
| 2026-10-07 | Thêm Service UUID `021a9004-0382-4aea-bff4-6b3f1c5adfb4` vào requirement (REQ-032a) |
| 2026-10-07 | Quét BLE chỉ lọc theo Service UUID (bỏ lọc theo tên `PROV_ESP32_`) |
| 2026-10-07 | PoP tạm `abcd1234` (`AppConfig.pop`), chờ xác nhận firmware (Q10) |
| 2026-10-07 | F03: tự kết nối + Sec1, ban đầu quét Wi-Fi qua `prov-scan`, Ethernet-only, gửi `prov-config`; thêm Q10–Q12; M-01 chờ test thiết bị thật |
| 2026-10-12 | Chuyển scan sang JSON Protocomm Security 1 tại endpoint `wifi-scan`/UUID FF54; phần xác minh phần cứng vẫn pending |
