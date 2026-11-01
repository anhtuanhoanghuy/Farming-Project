# Mobile App Requirement – Hệ thống Giám sát & Điều khiển Ao nuôi Thủy sản / IoT (ESP32-S3)

Nguồn: `Mobile_requirement.docx` – Revision 2.0 (07/10/2026), contract-aligned với *ESP32-S3 Controller Specification*.
Mỗi yêu cầu có ID (`REQ-*`) để truy vết sang [plan.md](plan.md) và [pipeline.md](pipeline.md).

## 1. Mục đích và nguyên tắc

- **REQ-001** Mobile là *protocol client* của ESP32-S3; không tự định nghĩa protocol, topic, field JSON, thiết bị hay capability mà firmware chưa công bố.
- **REQ-002** Nguồn chuẩn: `app_ble_prov`, `app_mqtt`, `app_modbus`, `app_control`, `app_nvm`, `app_sysmon`, `main_data_types.h`.
- **REQ-003** BLE: ESP-IDF Protocomm + NimBLE, service prefix `PROV_ESP32_`, Security **Sec1**.
- **REQ-004** MQTT: Command/ACK/Set QoS 1; Telemetry QoS 0.
- **REQ-005** Số lượng cảm biến/tải do controller quyết định; không giả định 4 relay.
- **REQ-006** Account/backend, scheduler, historical DB, master-off, dynamic user topic **chỉ** triển khai khi có contract bổ sung (ngoài phạm vi hiện tại).

## 2. Kiến trúc

Ứng dụng Flutter (Android) gồm các lớp:

| Layer | Trách nhiệm | Giao tiếp |
|---|---|---|
| Presentation / UI | Device list, dashboard, sensor cards, load control, configuration, diagnostics | Flutter UI |
| Device Session Manager | Device đang chọn, connection state, MQTT subscription, BLE session | MQTT/BLE |
| MQTT Service | Subscribe/publish 5 topic, QoS, reconnect, route message theo device | Broker |
| BLE Provisioning Service | Scan `PROV_ESP32_`, Protocomm, gọi 4 custom endpoint | BLE Sec1 |
| Protocol / JSON Mapper | Serialize/deserialize đúng field & kiểu | JSON |
| Device State Store | Snapshot sensor/load/network/error cho UI | In-memory / local storage |
| Diagnostics / Developer Console | Raw MQTT/BLE JSON, ACK, status, lỗi | Logs |

## 3. Dynamic Interface Capability Model

Controller công bố:

```json
{
  "capabilities": {
    "rs485": { "supported": true, "count": 4 },
    "analog_4_20ma": { "supported": true, "count": 1 },
    "loads": { "supported": true, "count": 4 }
  },
  "runtime_interfaces": {
    "rs485_used": 3,
    "analog_4_20ma_used": 0,
    "loads_used": 2
  }
}
```

- **REQ-010** Phân biệt `count` (tối đa phần cứng) và `used` (đã cấu hình).
- **REQ-011** Hiển thị danh sách cảm biến/tải đã cấu hình.
- **REQ-012** Nếu `rs485_used < rs485.count` → hiển thị đúng **01** ô "Add Sensor" (cổng trống kế tiếp).
- **REQ-013** Nếu `rs485_used == rs485.count` → ẩn hoàn toàn "Add Sensor".
- **REQ-014** Loads và 4-20mA render động theo cặp `count` vs `used` tương tự.

## 4. Device Identity & MQTT Topic Contract

MQTT Client_ID của controller = Device ID/MAC. Mobile dùng Client_ID riêng, ổn định theo installation để một kết nối có thể subscribe nhiều thiết bị; không dùng trùng Client_ID của controller.

| Topic | Hướng | QoS | Mục đích |
|---|---|---|---|
| `v1/{user_id}/devices/{device_id}/telemetry` | ESP32 → Mobile | 0 | Sensor realtime |
| `v1/{user_id}/devices/{device_id}/commands` | Mobile → ESP32 | 1 | Điều khiển tải |
| `v1/{user_id}/devices/{device_id}/ack` | ESP32 → Mobile | 1 | ACK command/config |
| `v1/{user_id}/devices/{device_id}/config/set` | Mobile → ESP32 | 1 | Cập nhật cấu hình |
| `v1/{user_id}/devices/{device_id}/status` | ESP32 → Mobile | theo broker | Trạng thái thiết bị |

- **REQ-020** Chỉ dùng đúng 5 topic trên.
- MQTT broker mặc định: `103.98.150.157:1883`, plaintext, không username/password. Có thể override host/port/TLS qua `MQTT_HOST`, `MQTT_PORT`, `MQTT_TLS`; thông tin xác thực mặc định để trống. Không ghi credentials vào traffic log.

## 5. BLE Provisioning

- **REQ-030** Service prefix `PROV_ESP32_`; BLE chỉ hoạt động ở `STATE_BLE_PROV`.
- **REQ-031** Sau khi App đọc kết quả cuối provisioning, controller dừng phiên BLE và khôi phục hoạt động mạng; chỉ lưu cấu hình khi kết quả yêu cầu lưu và ghi NVS thành công.
- **REQ-032** Endpoint `prov-config` (App → ESP32) nhận đúng bốn field `ssid`, `password`, `user_id`, `only_use_ethernet`.
- **REQ-032a** Service UUID (128-bit) của Protocomm provisioning service: `021a9004-0382-4aea-bff4-6b3f1c5adfb4`. App dùng UUID này làm tiêu chí **duy nhất** để xác định thiết bị hợp lệ khi quét (không lọc theo tên); firmware phải đưa UUID này vào gói quảng bá BLE.

Firmware (NimBLE, little-endian) khai báo:

```c
static const uint8_t s_service_uuid[BLE_UUID128_VAL_LENGTH] = {
    0xb4, 0xdf, 0x5a, 0x1c, 0x3f, 0x6b, 0xf4, 0xbf,
    0xea, 0x4a, 0x82, 0x03, 0x04, 0x90, 0x1a, 0x02,
};
```

Chuỗi UUID trên App là thứ tự byte đảo ngược của mảng này.

- **REQ-032b** Khi người dùng chọn một thiết bị đã quét, App tự kết nối BLE, khám phá endpoint (mô tả GATT 0x2901) và thiết lập phiên Protocomm Sec1 (X25519 + AES-256-CTR, PoP nếu có) trước khi sang bước Wi-Fi.
- **REQ-032c** Wi-Fi scan gọi trực tiếp endpoint `wifi-scan` (characteristic UUID `0xFF54`) trên session Protocomm Security 1; request/response là JSON mã hóa, không dùng protobuf `prov-scan`. Gửi `{"start":0}` để bắt đầu/lấy trang đầu, sau đó `{"start":N}` để lấy trang tiếp theo theo offset. Response có `total` và danh sách AP (`ssid`, `rssi`, `auth`), tối đa 20 AP; `wifi_unavailable` báo radio không khả dụng.
- **REQ-032d** Chỉ hiển thị mạng Wi-Fi có bảo mật (không Open, không WPA2-Enterprise), mỗi SSID một dòng (tín hiệu mạnh nhất).
- **REQ-032e** Checkbox "Chỉ sử dụng Ethernet": khi bật → không quét Wi-Fi, ẩn danh sách mạng và gửi `ssid`/`password` rỗng cùng `only_use_ethernet: true`; khi tắt → tự quét và gửi thông tin Wi-Fi cùng `only_use_ethernet: false`.
- **REQ-032f** Chọn một Wi-Fi thì ô mật khẩu hiện ngay dưới mạng đó; nút gửi cấu hình chỉ bật khi mật khẩu hợp lệ (REQ-090).
- **REQ-032g** `prov-config` trả `IN_PROGRESS` khi nhận cấu hình; App poll `prov-status` đến `state: done`, xử lý `SUCCESS`/`WARNING`/`ERROR`, và dùng `device_id` STA MAC từ phản hồi cuối để đăng ký thiết bị. Timeout phía App là 90 giây.

### 5.1 `prov-config` (BLE)

```json
{
  "ssid": "Factory_AP_01",
  "password": "SecretKey123",
  "user_id": "usr_99218472",
  "only_use_ethernet": false
}
```

`prov-config` trả lời ban đầu `{"status":"IN_PROGRESS","device_id":"aabbccddeeff"}`. App poll endpoint `prov-status` (request `{}`); response có `state: idle|in_progress|done`. Khi `done`, response gồm `status: SUCCESS|WARNING|ERROR`, `saved`, `attempts`, `device_id` và có thể có `code`, `reason`, `message`. `SUCCESS` và `WARNING` chỉ được coi là hoàn tất cấu hình khi `saved` là `true`; `WARNING` có thể là Wi-Fi lỗi nhưng Ethernet đang hoạt động.

### 5.2 `sensor-config` (MQTT, topic `set`)

```json
{ "sensor_type": "ph", "slave_id": 3, "name": "pH_Tank_A1", "enabled": true }
```

| Field | Kiểu | Rule |
|---|---|---|
| `sensor_type` | string | `sht40` / `do` / `ph`; không thêm loại khác |
| `slave_id` | integer | 1–247 |
| `name` | string | ≤ 32 ký tự (`char[32]`) |
| `enabled` | boolean | true/false |

### 5.3 `load-ctrl` (MQTT, topic `commands`)

```json
{ "action": "SET_STATE", "load_id": 1, "state": true, "duration_sec": 60, "new_name": "Pump_Water_A" }
```

- **REQ-033** `load_id` hiện hỗ trợ mặc định = 1 (`load_1_name`).
- **REQ-034** `state` true = bật, false = tắt.
- **REQ-035** `duration_sec` = 0: không tự tắt; > 0: controller tự tắt sau thời gian đó.
- **REQ-036** `new_name` dùng khi đổi tên tải; không tạo `action` khác ngoài contract.

## 6. `sys-status` (MQTT)

```json
{
  "net_interface": "ETH",
  "sensors": {
    "sht40": {"name": "Temp_Humid_Room", "temp": 29.1, "humid": 68.4, "valid": true},
    "do":    {"name": "DO_Tank_1", "do_mg_l": 6.82, "valid": true},
    "ph":    {"name": "pH_Tank_A1", "ph_val": 7.15, "valid": true}
  },
  "loads": { "load_1": {"name": "Pump_Water_A", "state": true} },
  "errors": { "code_mask": 1, "messages": ["SYS_ERR_MODBUS_TIMEOUT on pH Sensor"] }
}
```

- **REQ-040** `valid=false` không được coi cả device offline.
- **REQ-041** `net_interface` ít nhất: ETH / Wi-Fi / không có interface (`net_interface_t`).
- **REQ-042** `code_mask` là bitmask, decode theo `sys_error_code_t`.

## 7. Cấu trúc dữ liệu cần phản ánh

| C struct | Field chính | Dùng cho |
|---|---|---|
| `app_config_t` | Wi-Fi, MQTT, `sht40_cfg`, `do_cfg`, `ph_cfg`, `load_1_name`, `safety_timeout_s` | Device settings |
| `modbus_sensor_cfg_t` | `slave_id`, `name[32]`, `enabled` | Form cấu hình sensor |
| `sensor_data_t` | temperature, humidity, do_mg_l, ph_val, valid flags, timestamp | Model telemetry |
| `load_command_t` | `cmd_id`, `load_id`, `target_state`, `duration_sec` | Command state / ACK correlation |
| `config_update_cmd_t` | Wi-Fi/MQTT, sensor update, load name | Config command |

## 8. Device State & UX

| ESP32 State | Mobile hiển thị | Thao tác cho phép |
|---|---|---|
| `STATE_INIT` | Connecting / Initializing | Chờ |
| `STATE_BLE_PROV` | Provisioning mode / Add Device | BLE provisioning |
| `STATE_NET_CONNECTING` | Connecting network | Không điều khiển tải qua MQTT |
| `STATE_OPERATIONAL` | Online / Operational | Dashboard, telemetry, command, config |
| `STATE_FAILOVER` | Degraded / Reconnecting | Cảnh báo; theo dõi recovery |
| `STATE_FACTORY_RESET` | Provisioning after reboot | Quay lại BLE provisioning |

## 9. Error Model

| Bit | Error | Hành vi Mobile | Severity |
|---|---|---|---|
| `1<<0` | `SYS_ERR_MODBUS_TIMEOUT` | Sensor invalid; cảnh báo giao tiếp sensor | Warning (sensor) |
| `1<<1` | `SYS_ERR_NET_LOST` | Offline/degraded | Warning |
| `1<<2` | `SYS_ERR_MQTT_BROKER` | Broker unavailable | Warning |
| `1<<3` | `SYS_ERR_NVM_FAIL` | Lỗi cấu hình/lưu trữ nghiêm trọng | Critical |
| `1<<4` | `SYS_ERR_SENSOR_OUT_RANGE` | Giá trị ngoài ngưỡng an toàn | (theo controller) |

- **REQ-050** UI phản ánh cùng semantic severity với LED_ERROR, không cần mô phỏng animation.

## 10. Dashboard (thứ tự ưu tiên)

1. **REQ-060** Header: tên thiết bị, Device ID/MAC rút gọn, Online/Offline, interface (ETH/Wi-Fi).
2. **REQ-061** Network status card.
3. **REQ-062** Sensor grid: 3 card SHT40, DO, pH – tên, giá trị, đơn vị, valid/error.
4. **REQ-063** Actuator card: Load 1, tên, ON/OFF, countdown nếu `duration_sec > 0`.
5. **REQ-064** System alert panel: code mask + messages.
6. **REQ-065** Historical chart: chỉ vẽ telemetry Mobile/backend thực sự lưu; ESP32 không có history API.
7. **REQ-066** Actions/settings: cấu hình sensor, load name, diagnostics.

## 11. Màn hình

| Screen | Thành phần | Yêu cầu |
|---|---|---|
| Device List | Device cards, Add Device | Trạng thái lấy từ Database |
| Add Device | BLE scan, Wi-Fi SSID/password hoặc Ethernet-only | Gửi đúng `prov-config`, poll `prov-status` |
| Device Dashboard | Network + Sensors + Load + Errors | Gửi `GET_STATUS` mỗi 15 giây; snapshot trạng thái hoặc telemetry hợp lệ chuyển Trực tuyến/duy trì online, không nhận status/telemetry trong 15 giây chuyển Đang chờ trạng thái, LWT chuyển Ngoại tuyến ngay |
| Sensor Configuration | Selector, Slave ID, Name, Enable | Validate ID 1–247; gửi `sensor-config` |
| Load Configuration | Load 1 name, state, duration | Gửi `load-ctrl`; không tạo UI load 2–4 nếu contract chưa mở rộng |
| Diagnostics | Error list, raw JSON, connection state | Hỗ trợ kỹ thuật; dùng chung polling `GET_STATUS` 15 giây và trạng thái presence từ snapshot/telemetry/LWT |
| Developer Console | Raw MQTT/BLE traffic | Filter Telemetry / Command / ACK / Config / Status |

## 12. Realtime Telemetry & Chart

- **REQ-070** Model theo `sensor_data_t`; **không tự bịa schema telemetry**. Khi firmware chốt JSON, mapper dùng đúng schema đó.
- **REQ-071** Chỉ render giá trị `valid=true`; invalid hiển thị trạng thái lỗi/không khả dụng.
- **REQ-072** `timestamp` làm trục thời gian nếu payload có.
- **REQ-073** Chart giờ/ngày/tuần/tháng là capability phía Mobile/backend.

## 13. Actuator Control Rules

- **REQ-080** Command có `cmd_id` UUID để đối chiếu ACK.
- **REQ-081** `load_id` hiện hỗ trợ 1.
- **REQ-082** Target state & duration phản ánh chính xác lên UI.
- **REQ-083** Safety interlock (`SYS_ERR_NET_LOST` > `safety_timeout_s`) ép tải LOW → UI hiển thị trạng thái thực tế/alert.
- **REQ-084** Sau safety shutdown controller không tự bật lại; Mobile cần command mới.
- **REQ-085** Không có scheduler / master emergency-stop.
- **REQ-086** Màn hình cấu hình tải cho phép cấu hình đồng thời hẹn giờ trễ, điều kiện cảm biến và lịch hẹn. UI giải thích thứ tự ưu tiên: dừng khẩn cấp/tải vô hiệu hóa > điều khiển thủ công > hẹn giờ trễ > điều kiện cảm biến > lịch hẹn.
- **REQ-087** Trước mỗi thao tác thêm điều kiện hoặc lịch hẹn, hiển thị hộp thoại giải thích ưu tiên và hành vi xung đột; “Hủy” đóng hộp thoại và không gửi lệnh thêm, “Đã hiểu, tiếp tục” đóng hộp thoại rồi mới gửi lệnh.
- **REQ-088** Khi hẹn giờ trễ đang chạy, điều kiện và lịch không điều khiển tải. Điều kiện cảm biến được xét trên mẫu mới và ưu tiên hơn lịch. Nếu điều kiện đang tác động đúng phút lịch, sự kiện lịch có thể bị bỏ qua và không chạy bù.
- **REQ-089** Lệnh điều khiển thủ công có thể tắt điều kiện và lịch đang bật của tải; UI phải đồng bộ lại từ trạng thái thiết bị sau ACK.

### Hiển thị cài đặt trễ và hướng màn hình

- App chỉ sử dụng màn hình dọc (portrait upright) trên Android và iOS, kể cả iPad; không xoay ngang hoặc lật ngược.
- Khi tải đang bật và không có hẹn giờ đang chạy, mặc định hiển thị “Thời gian tắt”, “Thời gian bật kể từ khi tắt” và nút “Đổi sang bật”.
- Khi tải đang tắt và không có hẹn giờ đang chạy, mặc định hiển thị “Thời gian bật”, “Thời gian tắt kể từ khi bật” và nút “Đổi sang tắt”.
- Nút đổi chế độ vẫn hoạt động như trước và giữ số phút đã nhập. Chế độ người dùng chọn không bị ghi đè bởi snapshot có cùng trạng thái tải; khi trạng thái tải thay đổi, mặc định được cập nhật theo trạng thái mới.
- Hẹn giờ đang chạy giữ chế độ đã gửi và khóa nút đổi chế độ; không đảo chế độ giữa hai pha.

## 14. Configuration Rules

- **REQ-090** `wifi_ssid` ≤ 32, `wifi_password` ≤ 64 (buffer); mật khẩu Wi-Fi nhập trên App: 8–63 ký tự ASCII in được (chuẩn WPA2-PSK).
- **REQ-091** Sensor name ≤ 32; Slave ID 1–247.
- **REQ-092** Load name ≤ 32 (`load_1_name`).
- **REQ-093** `safety_timeout_s` chỉ cấu hình khi firmware có command/config path (hiện chưa có JSON example).
- **REQ-094** DI enabled có tên `ON1_...` .. `ON4_...` hoặc `OFF1_...` .. `OFF4_...` là nút momentary điều khiển tải tương ứng. Nhấn ON bật, nhấn OFF tắt; app nhận sự kiện cạnh nhấn từ firmware. Nút vật lý và công tắc tải trên app ngang quyền, lệnh mới nhất thắng.
- **REQ-095** DI `ONx_`/`OFFx_` không hiện trong danh sách cảm biến vận hành, diagnostics hoặc lựa chọn sensor cho điều kiện tải; vẫn hiện và sửa được trong quản lý/cấu hình cảm biến. Disable DI hoặc bỏ tiền tố trả DI về cảm biến thường.

## 15. MQTT Session

- **REQ-100** Khi operational, subscribe các topic controller công bố.
- **REQ-101** Command/config QoS 1; UI ở trạng thái **Pending** đến khi có ACK hoặc timeout.
- **REQ-102** Telemetry QoS 0: mất sample không coi là offline.
- **REQ-103** `status` xác định availability của device.
- **REQ-104** Reconnect phải khôi phục subscription và refresh UI.

## 16. Developer Mode

- **REQ-110** Nhấn 10 lần vào App Version để bật.
- **REQ-111** Console hiển thị raw JSON Telemetry, Command, ACK, Set, Status, BLE endpoint traffic theo device.
- **REQ-112** Hiển thị timestamp, direction (RX/TX), transport (BLE/MQTT), topic/endpoint.
- **REQ-113** Không hiển thị/log plaintext Wi-Fi/MQTT password.

## 17. Security

- **REQ-120** BLE dùng Protocomm Sec1.
- **REQ-121** Không log password ở production.
- **REQ-122** MQTT TLS theo cấu hình broker firmware hỗ trợ; không tự suy diễn certificate workflow.
- **REQ-123** Account/OTP/backend auth không phải prerequisite của protocol thiết bị.

## 18. Acceptance Criteria

| ID | Test | Pass criteria |
|---|---|---|
| M-01 | BLE Provisioning | Scan/connect, gửi đủ 4 field theo firmware, poll `prov-status`, lưu đúng `device_id` STA MAC |
| M-02 | Sensor Config | Đổi pH name, slave_id, enabled; ESP32 cập nhật |
| M-03 | Load Control | `SET_STATE` load_id=1 với state+duration; UI phản ánh command/ACK |
| M-04 | System Status | Parse đúng net_interface, 3 sensor, load_1, error mask/messages |
| M-05 | MQTT Topics | Chỉ dùng 5 topic chuẩn của controller |
| M-06 | Error Decode | Decode đúng 5 `SYS_ERR_*` và severity |
| M-07 | Failover UI | ETH↔Wi-Fi cập nhật active interface; không coi là sensor failure |
| M-08 | Safety Interlock | Mất mạng lâu + tải bị ép OFF → cảnh báo, không tự bật lại |
| M-09 | Developer Mode | Hiển thị raw JSON MQTT/BLE |
| M-10 | Contract Integrity | Không gửi field/topic/command ngoài spec |

## 19. Mapping Mobile ↔ ESP32 Components

| ESP32 component | Mobile dependency |
|---|---|
| `app_ble_prov` | BLE scanner, Protocomm client, 4 endpoints, JSON |
| `app_mqtt` | 5 topic, QoS, telemetry/command/ack/config/status |
| `app_modbus` | Sensor model SHT40/DO/pH + config |
| `app_control` | Load command, duration, safety interlock |
| `app_nvm` | Persistence semantics Wi-Fi/MQTT/sensor/load |
| `app_network` | ETH/Wi-Fi active interface, failover |
| `app_sysmon` | Error mask, severity, diagnostics |

## 20. Điểm mâu thuẫn / chưa rõ trong tài liệu gốc (cần chốt với firmware)

| # | Vấn đề | Ảnh hưởng |
|---|---|---|
| Q1 | Topic Mobile cũ dùng `v1/users/{user_id}/devices/{device_id}/…` và `/set`, không khớp contract firmware | Đã chốt theo firmware: `v1/{user_id}/devices/{device_id}/…`, cấu hình ở `/config/set`; M-05 và toàn bộ builder/router dùng contract này |
| Q2 | "4 BLE Custom Endpoints" nhưng chỉ mô tả `prov-config` (sensor-config/load-ctrl lại gửi qua MQTT) | Firmware có `prov-session`, `prov-config`, `prov-status`, `wifi-scan`; sensor/load config đi qua MQTT |
| Q3 | Add Device có "MQTT URL, port" nhưng `prov-config` chỉ có 3 field (ssid, pass, user_id) | Đã chốt theo firmware: không gửi MQTT URL/port; `prov-config` gồm `ssid`, `password`, `user_id`, `only_use_ethernet` |
| Q4 | Mục 3 nói `loads.count = 4` dynamic, nhưng mục 5/11/13 chỉ hỗ trợ load 1 | Prototype UI hiện có 4 tải; cần quyết định |
| Q5 | Chưa có JSON telemetry đầy đủ | Chặn mapper telemetry (chỉ dùng `sys-status` tạm) |
| Q6 | Schema ACK chưa được mô tả (field `cmd_id`, status/result?) | Chặn correlation ACK |
| Q7 | `user_id` lấy từ đâu khi không có account/backend contract | Chặn luồng Login/Register |
| Q8 | `status` topic payload, QoS không rõ | Chặn availability logic |
| Q9 | Mapping bit `SYS_ERR_SENSOR_OUT_RANGE` severity chưa rõ | Hiển thị severity |
| Q10 | Protocomm Sec1 có dùng Proof-of-Possession (PoP) không, giá trị là gì | App đang dùng PoP tạm `abcd1234` (`AppConfig.pop`); sai thì handshake thất bại |
| Q11 | Chế độ Ethernet-only gửi `prov-config` thế nào | Đã chốt theo firmware: gửi `ssid`/`password` rỗng và `only_use_ethernet: true` |
| Q12 | Firmware có bật endpoint `wifi-scan` không (Q2 liên quan); `user_id` lấy từ đâu | Firmware có `wifi-scan`; App dùng endpoint này. `user_id` vẫn lấy từ Auth/AppConfig cho đến khi có backend contract |
