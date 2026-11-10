# MQTT JSON Payload Contract: Load Control

Phiên bản 1.3, ngày 2026-10-08. Đây là contract cho mobile app và MCU; mọi message là JSON object UTF-8, có `v: 1` và `cmd_id` (1–36 ký tự `[A-Za-z0-9_-]`). Topic gốc:

```text
v1/{user_id}/devices/{device_id}/commands
v1/{user_id}/devices/{device_id}/config/set
v1/{user_id}/devices/{device_id}/ack
v1/{user_id}/devices/{device_id}/status
```

`commands`, `config/set`, `ack`, `status` dùng QoS 1. Lệnh/config retained bị MCU bỏ qua. Message nhận phải phẳng; không gửi object/array lồng nhau. Snapshot/status do MCU gửi có thể chứa object/array.

## 1. Cho phép điều khiển tải

`enabled` là quyền cho phép điều khiển tải, không phải trạng thái relay. Gửi cấu hình đầy đủ tới `config/set`:

```json
{
  "v": 1,
  "cmd_id": "policy-01",
  "type": "load_control",
  "load_id": 1,
  "enabled": true,
  "schedule_enabled": true,
  "days_mask": 31,
  "on_time_utc": "06:00",
  "off_time_utc": "18:00",
  "on_condition_enabled": false,
  "on_sensor_id": "sensor_001",
  "on_operator": "lt",
  "on_threshold": 10,
  "off_condition_enabled": false,
  "off_sensor_id": "sensor_001",
  "off_operator": "gt",
  "off_threshold": 20
}
```

| Field | Type / miền | Ý nghĩa |
| --- | --- | --- |
| `type` | string: `load_control` | Cập nhật quyền và lịch của một tải |
| `load_id` | integer 1..4 | ID tải, 1-based |
| `enabled` | boolean | Cho phép/từ chối điều khiển tải |
| `schedule_enabled` | boolean | Bật/tắt lịch tuần |
| `days_mask` | integer 0..127 | Bit 0=Mon, 1=Tue, 2=Wed, 3=Thu, 4=Fri, 5=Sat, 6=Sun; ví dụ 31=Mon–Fri |
| `on_time_utc` | string `HH:mm` | Giờ bật theo UTC |
| `off_time_utc` | string `HH:mm` | Giờ tắt theo UTC |
| `on_condition_enabled` | boolean | Bật rule điều kiện cảm biến để bật tải |
| `on_sensor_id` | `sensor_001`…`sensor_005` | Sensor được dùng cho rule bật |
| `on_operator` | `lt`, `lte`, `eq`, `gte`, `gt` | Toán tử so sánh của rule bật |
| `on_threshold` | số hữu hạn, -1,000,000..1,000,000 | Ngưỡng của rule bật |
| `off_condition_enabled` | boolean | Bật rule điều kiện cảm biến để tắt tải |
| `off_sensor_id` | `sensor_001`…`sensor_005` | Sensor được dùng cho rule tắt |
| `off_operator` | `lt`, `lte`, `eq`, `gte`, `gt` | Toán tử so sánh của rule tắt |
| `off_threshold` | số hữu hạn, -1,000,000..1,000,000 | Ngưỡng của rule tắt |

Đây là full-replace config: gửi đủ tất cả field, kể cả hai nhóm điều kiện khi nhóm đó đang tắt. Nếu `schedule_enabled=true`, `days_mask` phải khác 0. Không được đồng thời bật lịch tuần và một trong hai rule cảm biến. MCU lưu cấu hình riêng từng tải vào NVS schema v3. Khi `enabled=false`, MCU chuẩn hóa `schedule_enabled=false`, xóa `days_mask`, tắt hai rule cảm biến, tắt tải ngay, hủy chu kỳ đang chờ và không nhận lệnh điều khiển cho đến khi được enable lại. Mobile app phải đổi giờ địa phương sang UTC trước khi gửi; UI có thể hiển thị giờ địa phương.

Sensor ID ổn định theo slot phần cứng: `sensor_001`…`sensor_004` tương ứng RS485 `interface_index` 0…3; `sensor_005` là analog 4–20 mA `interface_index` 0. Các ID này được phát trong từng sensor object của telemetry/snapshot. Giá trị chính `v1` dùng cho rule: SHT40 `temp` (°C), DO `do_mg_l` (mg/L), pH `ph_val`, analog `current_ma` (mA). Các đại lượng phụ theo register map được phát thêm (`humid`, DO `temperature_c`/`do_saturation_pct`, pH `temperature_c`). Rule chỉ được xét khi nhận sample mới hợp lệ cho đúng ID; nếu sample của sensor được tham chiếu bị thiếu, invalid hoặc không hữu hạn, firmware đưa tải về OFF.

Khi điều kiện ON và OFF cùng khớp trong một chu kỳ cảm biến, OFF được ưu tiên. Có `SET_STATE`/`SET_LOAD_CYCLE` đang chạy thì rule cảm biến bị bỏ qua; E-STOP luôn chặn bật, Interlock cho phép điều kiện OFF nhưng chặn ON. Một rule khớp sẽ giữ relay ở trạng thái tương ứng cho tới lần sample hợp lệ tiếp theo kích hoạt rule còn lại. Nếu không rule nào khớp, relay giữ nguyên trạng thái. Cấu hình điều kiện nằm ở `config/set`, không phải action mới trong `commands`; firmware thực thi rule cục bộ ngay cả khi MQTT tạm mất kết nối.

Ví dụ bật tải 1 khi `sensor_001 < 10`, tắt khi `sensor_001 >= 20`:

```json
{
  "v": 1,
  "cmd_id": "sensor-rule-01",
  "type": "load_control",
  "load_id": 1,
  "enabled": true,
  "schedule_enabled": false,
  "days_mask": 0,
  "on_time_utc": "00:00",
  "off_time_utc": "00:00",
  "on_condition_enabled": true,
  "on_sensor_id": "sensor_001",
  "on_operator": "lt",
  "on_threshold": 10,
  "off_condition_enabled": true,
  "off_sensor_id": "sensor_001",
  "off_operator": "gte",
  "off_threshold": 20
}
```

Nếu muốn chỉ bật hoặc chỉ tắt theo cảm biến, đặt nhóm rule còn lại `*_condition_enabled:false`. Muốn xóa rule, gửi full-replace với `false`. Hai điều kiện được phép dùng sensor ID khác nhau.

Mỗi ngày được chọn bắt đầu một chu kỳ tại `on_time_utc`; tắt tại `off_time_utc`. Nếu giờ tắt nhỏ hơn hoặc bằng giờ bật, giờ tắt thuộc ngày UTC kế tiếp. Lịch chỉ chạy khi thời gian đã đồng bộ (`BIT_TIME_VALID`). MCU dùng SNTP để lấy giờ chuẩn và cấu hình cập nhật lại mỗi 1 giờ (`CONFIG_LWIP_SNTP_UPDATE_DELAY=3600000`); firmware đọc thời gian bằng C time API (`time()`/`gmtime_r()`), đồng hồ hệ thống duy trì giờ giữa các lần đồng bộ, không truy vấn NTP liên tục. Mốc lịch xảy ra trong lúc chu kỳ tay đang chạy bị bỏ qua; lịch không phát bù mốc đã qua.

## 2. Bật/tắt thông thường

Lệnh đổi relay tức thời vẫn dùng `commands`:

```json
{"v":1,"cmd_id":"state-01","action":"SET_STATE","load_id":1,"state":true}
```

`state=true` bật; `false` tắt. `duration_min` (0..86400 phút) tự tắt sau khi bật; `0` nghĩa là không tự tắt. MCU vẫn nhận `duration_sec` cũ để tương thích ngược, nhưng không được gửi đồng thời cả hai field. Giao diện có cặp delay/duration phải dùng `SET_LOAD_CYCLE` bên dưới.

Tải đang `enabled=false` phải từ chối lệnh `SET_STATE`/`SET_LOAD_CYCLE` với ACK lỗi `forbidden`. `SET_ALL_OFF` vẫn được phép như lệnh an toàn.

### 2.1 E-STOP có chốt

`EMERGENCY_STOP` tắt mọi relay, hủy cycle/timer, lưu latch trong NVS và set `BIT_SYS_ESTOP` để sensor task dừng polling:

```json
{"v":1,"cmd_id":"estop-01","action":"EMERGENCY_STOP"}
```

Thoát latch bằng `EMERGENCY_RELEASE`, bắt buộc `confirm:true`; relay không tự bật lại:

```json
{"v":1,"cmd_id":"estop-release-01","action":"EMERGENCY_RELEASE","confirm":true}
```

Hai action được xử lý đồng bộ, không qua `load_cmd_queue`; E-STOP không bị chặn bởi queue đầy, timestamp cũ, disable hay interlock. Retry cùng `cmd_id` là idempotent. Thiếu `confirm:true` trả `invalid_fields`.

## 3. Chu kỳ thời gian một lần

Cặp thời gian là **một command riêng**, gửi tới `commands`; không lưu thành lịch tuần. Delay và `duration` tính bằng phút, miền 0..1440. `duration=0` nghĩa là chỉ thực hiện lần đổi trạng thái đầu tiên, không tự đổi lần thứ hai.

### Bật trễ, rồi tắt sau thời gian chạy

```json
{
  "v": 1,
  "cmd_id": "cycle-01",
  "action": "SET_LOAD_CYCLE",
  "load_id": 1,
  "mode": "ON_THEN_OFF",
  "on_delay_min": 5,
  "duration": 60
}
```

MCU chờ `on_delay_min` rồi bật; sau đó chờ `duration` rồi tắt. `on_delay_min` có thể là 0. `duration=0` nghĩa là bật xong giữ ON vô thời hạn; `duration>0` là thời gian giữ ON trước khi tắt.

### Tắt trễ, rồi bật lại sau thời gian tắt

```json
{
  "v": 1,
  "cmd_id": "cycle-02",
  "action": "SET_LOAD_CYCLE",
  "load_id": 1,
  "mode": "OFF_THEN_ON",
  "off_delay_min": 0,
  "duration": 30
}
```

MCU chờ `off_delay_min` rồi tắt; sau đó chờ `duration` rồi bật lại. `off_delay_min` có thể là 0. `duration=0` nghĩa là tắt xong giữ OFF vô thời hạn; `duration>0` là thời gian giữ OFF trước khi bật lại. Chỉ gửi delay thuộc `mode` đã chọn. Khi nhận command cycle mới, MCU hủy cycle đang chờ trước đó của cùng tải. Lệnh tay đang chạy được ưu tiên so với mốc lịch tuần; mốc lịch xảy ra trong thời gian cycle bị bỏ qua.

## 4. ACK

ACK tải thành công giữ `kind=load`; với cycle, `load` echo lại mode, delay và `duration` đã nhận:

```json
{
  "v": 1,
  "cmd_id": "cycle-01",
  "kind": "load",
  "result": "ok",
  "code": "ok",
  "load": {
    "load_id": 1,
    "state": false,
    "duration_min": 0,
    "remaining_s": 300,
    "cycle_mode": "ON_THEN_OFF",
    "on_delay_min": 5,
    "duration": 60
  },
  "dup": false
}
```

`load.state` là trạng thái thực sau khi xử lý ACK; `remaining_s` là thời gian còn lại tới bước chuyển tiếp kế tiếp. ACK echo `cycle_mode`, delay tương ứng và `duration`. `SET_LOAD_CYCLE` chỉ thành công khi `app_control` đã nhận quyền điều khiển tải và khởi chạy cycle. ACK config thành công dùng `kind=config`, `config.type=load_control`, `config.load_id`, `config.changed`.

Các lỗi schema dùng mã hiện hành: `invalid_json`, `invalid_fields`, `invalid_value`, `unsupported_action`, `busy`, `forbidden`, `interlock_active`, `storage_error`, `internal_error`.

ACK E-STOP dùng `kind=emergency`:

```json
{"v":1,"cmd_id":"estop-01","kind":"emergency","result":"ok","code":"ok","emergency":{"active":true,"changed":true,"loads_off":4},"dup":false}
```

Khi bị E-STOP chặn, lệnh bật trả `code:"emergency_active"`.

## 5. Status snapshot

Mỗi phần tử trong `status` snapshot `loads[]` cần có các field sau để mobile app hiển thị đúng trạng thái và khôi phục cấu hình:

```json
{
  "load_id": 1,
  "name": "Bơm nước",
  "state": true,
  "enabled": true,
  "remaining_s": 120,
  "schedule_enabled": true,
  "days_mask": 31,
  "on_time_utc": "23:00",
  "off_time_utc": "06:00",
  "on_condition_enabled": false,
  "on_sensor_id": "sensor_001",
  "on_operator": "lt",
  "on_threshold": 10,
  "off_condition_enabled": false,
  "off_sensor_id": "sensor_001",
  "off_operator": "gt",
  "off_threshold": 20,
  "cycle_mode": "ON_THEN_OFF",
  "cycle_next": "off",
  "cycle_delay_min": 5,
  "cycle_duration_min": 60
}
```

`state` là trạng thái output thực tế; `enabled` là quyền điều khiển. Không dùng `state` để suy ra `enabled`.
Snapshot cấp cao nhất có `emergency: {"active":true|false}`. Khi E-STOP active, các sensor giữ identity nhưng có `valid:false,error:"stopped"`.

## 6. Ánh xạ MCU

- `commands/SET_STATE`, `commands/SET_LOAD_CYCLE` → `load_cmd_queue` (`load_command_t`); `SET_ALL_OFF` vẫn dùng queue này. `app_control` xử lý relay/cycle và gửi ACK; board execution tests pending.
- `config/set/type=load_control` → `config_cmd_queue` (`config_update_cmd_t`), cập nhật `app_config_t.load_control[load_id - 1]` và NVS schema v3.
- `commands/EMERGENCY_STOP` và `commands/EMERGENCY_RELEASE` gọi API đồng bộ `app_control`; trạng thái latch dùng key NVS riêng `estop`.
- Shared C definitions: `load_control_cfg_t`, `load_command_kind_t`, `load_cycle_mode_t`; parser/serializer: `app_mqtt_proto`.
- Lịch tuần và rule cảm biến `load_control[load_id-1]` được lưu trong NVS theo từng tải; schema v1/v2/v3 được migrate sang v4, rule cảm biến ở schema v1/v2 mặc định tắt.
- Mobile source không nằm trong workspace MCU này; app team cần áp dụng đúng tên field, enum, UTC conversion và bitmask trong tài liệu này.
- Parser, queue contract, NVS, ACK/snapshot và `app_control` đã được nối ở MCU. E-STOP đặt `BIT_SYS_ESTOP`; suspend/resume thật của polling phải được hoàn tất khi `app_modbus` (P4) được triển khai. Chưa thử trên board.
