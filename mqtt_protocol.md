# Tài liệu Đặc tả Giao thức MQTT (MQTT Protocol Specification)

Tài liệu này định nghĩa cấu trúc dữ liệu JSON cho toàn bộ 5 topic MQTT sử dụng trong giao tiếp giữa **Ứng dụng Flutter** và **Thiết bị giám sát / điều khiển ESP32-S3**.

---

## 1. Cấu trúc Topic chuẩn

Topic format:
```text
v1/{userId}/devices/{deviceId}/{leaf}
```

- **`{userId}`**: UUID tài khoản Supabase của người dùng (36 ký tự).
- **`{deviceId}`**: Địa chỉ MAC của ESP32 (12 ký tự hex viết thường, ví dụ: `84c7bb772310`).
- **`{leaf}`**: 1 trong 5 nhánh topic:
  1. `commands` (App ➔ ESP32)
  3. `ack` (ESP32 ➔ App)
  4. `status` (ESP32 ➔ App - Chứa Retained Snapshot, LWT & Events)
  5. `telemetry` (ESP32 ➔ App - Định kỳ)

---

## 2. Topic: `commands` (App ➔ ESP32)

Dùng để gửi các lệnh điều khiển tải trực tiếp, kích hoạt chu kỳ hoặc can thiệp khẩn cấp.

### 2.1. Bật / Tắt tải trực tiếp
Command này ra lệnh bật hoặc tắt tải tức thời. Command này luôn có priority cao hơn các config hẹn giờ trễ, hẹn lịch hay hẹn bật tắt theo điều kiện. Nếu tải đang được cấu hình các config như hẹn giờ trễ, hẹn lịch hay hẹn bật tắt theo điều kiện, thì khi dùng command này sẽ lập tức vô hiệu các config đó. (tức là nếu thỏa mãn điều kiện của config thì cũng không thể làm gì vì luôn ưu tiên điều khiển thủ công từ người dùng, timer cũng sẽ bị dừng). Ví dụ khi chuẩn bị đến giờ bật tải theo lịch hẹn mà người dùng bấm OFF thì khi đến giờ tải cũng không được bật lên. Cấu hình này không được lưu NVM
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "SET_LOAD_STATE",
  "load_id": "DO1",
  "action": true,
}
```
* **`load_id`**: Thứ tự cổng tải (`DO1` .. `DO4`).
* **`action`**: `true` (Bật) / `false` (Tắt).

---

### 2.2. Hẹn giờ trễ tải 
Command này sẽ bắt đầu đếm giờ trong esp, khi đạt đến điều kiện delay_min sẽ thực hiện hành động của mode trong suốt thời gian duration sau đó đảo ngược lại hành động (ví dụ sau delay_min phút thì ON trog suốt duration phút thì OFF đi và ngược lại). Nếu duration set là 0 thì sẽ luôn giữ trạng thái mà không đảo ngược hành động (ví dụ ON thì luôn ON). Cấu hình này chỉ thực hiện 1 lần duy nhất khi người dùng áp dụng. Sau khi hoàn tắt sẽ không chạy lại cho đến khi người dùng set lại. Cấu hình này không được lưu NVM
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "SET_LOAD_DELAY",
  "load_id": "DO1",
  "mode": false,
  "delay_min": 5,
  "duration": 30
}
```
* **`mode`**:
  * false _ `"ON_THEN_OFF"`: Chờ `delay_min` phút rồi bật trong `duration` phút rồi tắt.
  * true _ `"OFF_THEN_ON"`: Chờ `delay_min` phút rồi tắt trong `duration` phút rồi bật.


### 2.3. Đổi tên tải
Command này dùng để đổi tên cho từng tải. Cấu hình này được lưu NVM
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "SET_LOAD_NAME",
  "load_id": "DO1",
  "name": "Quạt nước 1"
}
```

### 2.4. Vô hiệu hóa/hiệu lực hóa tải.
Command này nếu set là false sẽ dừng ngay lập tức tải đang hoạt động và dừng các timer và logic liên quan đến hẹn lịch bật tắt, hẹn giờ trễ hay bật tắt theo điều kiện. Đồng thời các giá trị đó sẽ được set về 0.
Nếu đang từ disable mà enable lại thì nhưng config cũ cũng không được khôi phục lại, và tải vẫn trong trạng thái tắt. Cấu hình này được lưu NVM
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "TOGGLE_LOAD_CAPABILITY",
  "load_id": "DO1",
  "action": true 
}
```
* **`action`**: 
  * true: cho phép
  * false: vô hiệu hóa
---

### 2.5. Cấu hình kiểm soát tải theo điều kiện cảm biến
Command này dùng để cấu hình bật tắt tải theo điều kiện cảm biến. Nếu giá trị cảm biến thỏa mãn điều kiện operator so với threshold thì sẽ thực hiện hành động action. Cấu hình này được lưu NVM
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "SET_LOAD_CONDITION",
  "condition_id": "CON1",
  "condition_enabled": false,
  "load_id": "DO1",
  "action": true,
  "sensor_id": "RS1",
  "value_name": "Độ ẩm không khí",
  "operator": true,
  "threshold": 4.5,
}
```
* **`condition_enabled`**: Cho phép điều kiện này được hoạt động (`true`/`false`).
* **`value_name`**: Tên đại lượng trong `telemetry.input[].values[].name` của cảm biến đã chọn; firmware so sánh đúng đại lượng này.
* **`operator`: Các phép toán so sánh:
  * false: Nhỏ hơn (`<`)
  * true: Lớn hơn (`>`)
* **`threshold`: ngưỡng giá trị cảm biến
* **`action`**: 
  * true: bật tải
  * false: tắt tải
---


### 2.6. Cấu hình kiểm soát tải theo lịch hẹn
Command này dùng để cấu hình bật tắt tải theo lịch hẹn. Nếu thời gian hiện tại thỏa mãn điều kiện days_mask và on_time_utc thì bật tải, off_time_utc thì tắt tải. Cấu hình này được lưu NVM
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "SET_LOAD_SCHEDULE",
  "scheduler_id": "SHE1",
  "load_id": "DO1",
  "scheduler_enabled": true,
  "days_mask": 127,
  "on_time_utc": "06:00",
  "off_time_utc": "18:00",
}
* **`schedule_enabled`**: cho phép lịch hẹn này được hoạt động(`true`/`false`).
* **`days_mask`**: Bitmask các ngày áp dụng trong tuần (T2=1, T3=2, T4=4, T5=8, T6=16, T7=32, CN=64. Cả tuần = `127`,...).
* **`on_time_utc` / `off_time_utc`**: Giờ bật/tắt chuẩn UTC định dạng `HH:MM`.
---
```

### 2.7. Xóa 1 điều kiện bật tắt theo cảm biến.
Command sẽ xóa 1 điều kiện bật tắt theo giá trị cảm biến khỏi NVM và sẽ dừng timer và logic liên quan đến bật tắt theo điều kiện cảm biến tương ứng (những điều kiện còn lại vẫn hoạt động bình thường).
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "DELETE_LOAD_CONDITION",
  "condition_id": "CON1",
  "load_id": "DO1"
}
```

### 2.8. Xóa 1 điều kiện bật tắt theo lịch hẹn
Command sẽ xóa 1 điều kiện bật tắt theo lịch hẹn khỏi NVM và sẽ dừng timer và logic liên quan đến bật tắt theo lịch hẹn tương ứng (những lịch hẹn còn lại vẫn hoạt động bình thường).
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "DELETE_LOAD_SCHEDULER",
  "scheduler_id": "SHE1",
  "load_id": "DO1"
}
```

### 2.9. Thêm 1 điều kiện bật tắt theo cảm biến.
Command sẽ thêm 1 điều kiện bật tắt theo giá trị cảm biến trong NVM với giá trị mặc định là 0 và condition_enabled = false.
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "ADD_LOAD_CONDITION",
  "load_id": "DO1",
  "condition_id": "CON1"
}
```

### 2.10. Thêm 1 điều kiện bật tắt theo lịch hẹn
Command sẽ thêm 1 điều kiện bật tắt theo lịch hẹn trong NVM với giá trị mặc định là 0 và scheduler_enabled = false.
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "ADD_LOAD_SCHEDULER",
  "load_id": "DO1",
  "scheduler_id": "SHE1" 
}
```
### 2.11. Vô hiệu hóa/hiệu lực hóa 1 điều kiện bật tắt theo cảm biến.
Command sẽ vô hiệu hóa hoặc hiệu lực hóa 1 điều kiện bật tắt theo giá trị cảm biến trong NVM.
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "TOGGLE_LOAD_CONDITION",
  "load_id": "DO1",
  "condition_id": "CON1",
  "action": true
}
```
* **`action`: true: hiệu lực hóa, false: vô hiệu hóa

### 2.12. Vô hiệu hóa/hiệu lực hóa 1 điều kiện bật tắt theo lịch hẹn
Command sẽ vô hiệu hóa hoặc hiệu lực hóa 1 điều kiện bật tắt theo lịch hẹn trong NVM. Nếu vô hiệu hóa, timer cho điều kiện tương ứng sẽ dừng ngay. Nếu hiệu lực hóa, timer sẽ bắt đầu ngay
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "TOGGLE_LOAD_SCHEDULER",
  "load_id": "DO1",
  "scheduler_id": "SHE1",
  "action": true
}
```
* **`action`: true: hiệu lực hóa, false: vô hiệu hóa

### 2.13. Tắt hẹn trễ tải
Command này lập tức dừng timer liên quan đến hẹn giờ trễ tải và không thực thi tiếp logic của nó. Ví dụ nếu tải được bật do thỏa mãn thời gian hẹn bật trễ và bắt đầu đếm ngược thời gian chuẩn bị tắt, nếu người dùng dừng hẹn trễ thì timer sẽ dừng và thiết bị sẽ luôn bật. Cấu hình này không được lưu NVM.
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "STOP_LOAD_DELAY",
  "load_id": "DO1",
}
```

### 2.14. Cấu hình/Thêm Cảm biến
Command sẽ cấu hình hoặc thêm 1 cảm biến. Cấu hình này được lưu NVM.
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "SENSOR_CONFIG",
  "action": true,
  "enabled": true,
  "interface_type": "rs485",
  "sensor_id": "RS1",
  "slave_id": 1 (nếu có),
  "name": "Cảm biến Oxy"
}
```
* **`action`:
  * true: thêm cảm biến
  * false: sửa cảm biến
* **`interface_type`**: `"rs485"` hoặc `"analog_4_20ma"` (không có `slave_id`) hoặc DI (không có `slave_id`).
* **`slave_id`**: Địa chỉ Modbus RTU (`1`..`247`).

---

### 2.15. Xóa Cảm biến
Command sẽ xóa 1 cảm biến khỏi NVM và dừng logic đọc cảm biến này.
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "DELETE_SENSOR",
  "sensor_id": "RS1",
}
```
* **`enabled`: hiệu lực hóa/vô hiệu hóa cảm biến (true/false)
* **`interface_type`**: `"rs485"` hoặc `"analog_4_20ma"` (không có `slave_id`) hoặc DI (không có `slave_id`).
* **`slave_id`**: Địa chỉ Modbus RTU (`1`..`247`).

---
### 2.16. Vô hiệu hóa/hiệu lực hóa 1 cảm biến
Command sẽ vô hiệu hóa hoặc hiệu lực hóa 1 cảm biến trong NVM. Nếu vô hiệu hóa, esp sẽ dừng đọc giá trị của nó. Nếu hiệu lực hóa, esp sẽ đọc giá trị của nó
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "TOGGLE_SENSOR_CAPABILITY",
  "sensor_id": "RS1",
  "action": true
}
```
* **`action`: true: hiệu lực hóa, false: vô hiệu hóa

### 2.17. Đổi tên thiết bị
Command này dùng để đổi tên cho thiết bị. Cấu hình này được lưu NVM
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "SET_DEVICE_NAME",
  "name": "Ao nuôi 1"
}
```


### 2.18. Yêu cầu gửi lại snapshot trạng thái (`GET_STATUS`)
Lệnh này sử dụng để yêu cầu esp gửi bản tin status cho app
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "GET_STATUS"
}
```

---

### 2.19. Yêu cầu gửi lại telemetry (`GET_TELEMETRY`)
Yêu cầu ESP32 gửi ngay mẫu telemetry mới nhất lên topic `telemetry`. Nếu chu kỳ đọc cảm biến đầu tiên chưa hoàn tất, ESP32 trả ACK lỗi `BUSY`.
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "GET_TELEMETRY"
}
```

---

### 2.20. Dừng khẩn cấp
Lệnh này dùng để lập tức tắt mọi cảm biến và tải. Lệnh này có độ ưu tiên cao nhất, mọi timer và logic bật tắt của tải theo giá trị cảm biến, lịch hẹn, lịch hẹn trế đều bị dừng và vô hiệu hóa.
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "EMERGENCY_STOP"
}
```

## 3. Topic: `ack` (ESP32 ➔ App)

ESP32 phản hồi kết quả thực thi lệnh sau khi xử lý từ `commands`t`. Khi nhận được bản tn ack này tùy vào từng result ok hay error mà app sẽ đồng bộ trạng thái với esp để hiển thị đúng trên giao diện. Nếu là error sẽ hiển thị lỗi và nguyên nhân.

### 3.1. Phản hồi thành công cho cấu hình
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "ACK",
  "result": "ok",
  "code": "OK",
  "boot_id": "361d7646",
  "dup": false,
  "ts": 1791854906000
}
```

### 3.2. Phản hồi từ chối / Thất bại
```json
{
  "v": 1,
  "cmd_id": "",
  "type": "ACK",
  "result": "error",
  "code": "INVALID_VALUE",
  "reason": "load is disabled",
  "boot_id": "361d7646",
  "dup": false,
  "ts": 1791854906000
}
```

---

## 4. Topic: `status` (ESP32 ➔ App)

Bao gồm:
1. **Retained Snapshot** (Cấu hình & trạng thái tải được broker lưu lại).
2. **LWT** (Offline).
3. **Event** (Sự kiện tức thời).

### 4.1. Snapshot - Retained = 1
Được ESP32 gửi khi khởi động, định kỳ, và ngay sau mỗi lần thực hiện cấu hình thành công.
```json
{
  "v": 1,
  "type": "SNAPSHOT",
  "boot_id": "361d7646",
  "device_name": "Device_01",
  "net_interface": "WIFI",
  "uptime_ms": 3600000,
  "ts": 1791854906000,
  "capabilities": {
    "rs485": { "supported": true, "count": 4, "port_lists":["RS1","RS2","RS3","RS4"] },
    "analog_4_20ma": { "supported": true, "runtime_available": false, "count": 1, "port_lists":["AN1"] },
    "digital_inputs": { "supported": true, "runtime_available": false, "count": 4, "port_lists":["DI1","DI2","DI3","DI4"] },
    "loads": { "supported": true, "count": 4,"port_lists":["DO1","DO2","DO3","DO4"] }
  },
  "runtime_interfaces": {
    "rs485_used": 1,
    "analog_4_20ma_used": 0,
    "digital_input_used": 0,
    "loads_used": 1
  },
  "input": [
    {
      "interface_type": "rs485",
      "port_id": "RS1",
      "name": "Nhiệt độ & Độ ẩm",
      "enabled": true,
      "slave_id": 1,
      "valid": true,
      "value_names": ["Nhiệt độ không khí", "Độ ẩm không khí"]
    },
    {
      "interface_type": "rs485",
      "port_id": "RS2",
      "name": "Cảm biến PH",
      "enabled": true,
      "slave_id": 2,
      "valid": true,
    },
    {
      "interface_type": "rs485",
      "port_id": "RS3",
      "name": "Cảm biến oxy",
      "enabled": true,
      "slave_id": 3,
      "valid": true,
    }
  ],
  "loads": [
    {
      "load_id": "DO1",
      "name": "Quạt nước 1",
      "enabled": true,
      "state": true,
      "load_delay": {
        "start_time": "14:00",
        "mode": false,
        "delay_min": 5,
        "duration": 30
      },
      "load_condition": [
        {
          "condition_id":"CON1",
          "condition_enabled": false,
          "action": true,
          "sensor_id": "RS1",
          "operator": true,
          "threshold": 4.5,
        },
        {
          "condition_id":"CON2",
          "condition_enabled": false,
          "action": false,
          "sensor_id": "RS1",
          "operator": true,
          "threshold": 4.6,
        }
      ],
      "load_scheduler" [
        {
          "scheduler_id": "SHE1",
          "scheduler_enabled": true,
          "days_mask": 127,
          "on_time_utc": "06:00",
          "off_time_utc": "18:00",
        },
        {
          "scheduler_id": "SHE2",
          "scheduler_enabled": false,
          "days_mask": 127,
          "on_time_utc": "07:00",
          "off_time_utc": "09:00",
        },
        {
          "scheduler_id": "SHE3",
          "scheduler_enabled": false,
          "days_mask": 127,
          "on_time_utc": "02:00",
          "off_time_utc": "04:00",
        }
      ]
    },
    {
      "load_id": "DO2",
      "name": "Quạt nước 2",
      "enabled": true,
      "state": true,
      "load_delay": {
        "start_time": "14:00",
        "mode": false,
        "delay_min": 5,
        "duration": 30
      },
      "load_condition": [
        {
          "condition_id":"CON1",
          "condition_enabled": false,
          "action": true,
          "sensor_id": "RS1",
          "operator": true,
          "threshold": 4.5,
        },
        {
          "condition_id":"CON2",
          "condition_enabled": false,
          "action": false,
          "sensor_id": "RS1",
          "operator": true,
          "threshold": 4.6,
        }
      ],
      "load_scheduler" [
        {
          "scheduler_id": "SHE1",
          "scheduler_enabled": true,
          "days_mask": 127,
          "on_time_utc": "06:00",
          "off_time_utc": "18:00",
        },
        {
          "scheduler_id": "SHE2",
          "scheduler_enabled": false,
          "days_mask": 127,
          "on_time_utc": "07:00",
          "off_time_utc": "09:00",
        },
        {
          "scheduler_id": "SHE3",
          "scheduler_enabled": false,
          "days_mask": 127,
          "on_time_utc": "02:00",
          "off_time_utc": "04:00",
        }
      ]
    },
    {
      "load_id": "DO3",
      "name": "Quạt nước 3",
      "enabled": true,
      "state": true,
      "load_delay": {
        "start_time": "14:00",
        "mode": false,
        "delay_min": 5,
        "duration": 30
      },
      "load_condition": [
        {
          "condition_id":"CON1",
          "condition_enabled": false,
          "action": true,
          "sensor_id": "RS1",
          "operator": true,
          "threshold": 4.5,
        },
        {
          "condition_id":"CON2",
          "condition_enabled": false,
          "action": false,
          "sensor_id": "RS1",
          "operator": true,
          "threshold": 4.6,
        }
      ],
      "load_scheduler" [
        {
          "scheduler_id": "SHE1",
          "scheduler_enabled": true,
          "days_mask": 127,
          "on_time_utc": "06:00",
          "off_time_utc": "18:00",
        },
        {
          "scheduler_id": "SHE2",
          "scheduler_enabled": false,
          "days_mask": 127,
          "on_time_utc": "07:00",
          "off_time_utc": "09:00",
        },
        {
          "scheduler_id": "SHE3",
          "scheduler_enabled": false,
          "days_mask": 127,
          "on_time_utc": "02:00",
          "off_time_utc": "04:00",
        }
      ]
    },
    {
      "load_id": "DO4",
      "name": "Quạt nước 4",
      "enabled": true,
      "state": true,
      "load_delay": {
        "start_time": "14:00",
        "mode": false,
        "delay_min": 5,
        "duration": 30
      },
      "load_condition": [
        {
          "condition_id":"CON1",
          "condition_enabled": false,
          "action": true,
          "sensor_id": "RS1",
          "operator": true,
          "threshold": 4.5,
        },
        {
          "condition_id":"CON2",
          "condition_enabled": false,
          "action": false,
          "sensor_id": "RS1",
          "operator": true,
          "threshold": 4.6,
        }
      ],
      "load_scheduler" [
        {
          "scheduler_id": "SHE1",
          "scheduler_enabled": true,
          "days_mask": 127,
          "on_time_utc": "06:00",
          "off_time_utc": "18:00",
        },
        {
          "scheduler_id": "SHE2",
          "scheduler_enabled": false,
          "days_mask": 127,
          "on_time_utc": "07:00",
          "off_time_utc": "09:00",
        },
        {
          "scheduler_id": "SHE3",
          "scheduler_enabled": false,
          "days_mask": 127,
          "on_time_utc": "02:00",
          "off_time_utc": "04:00",
        }
      ]
    }
  ],
  "interlock": { "tripped": false },
  "emergency": { "active": false },
  "errors": {
    "code_mask": 0,
    "messages": []
  },
  "heap": { "free": 215000, "min_free": 198000 },
  "mqtt": { "reconnects": 1, "rx_rejected": 0, "tx_fail": 0, "telemetry_dropped": 0 }
}
```

`errors.code_mask` và `errors.messages` chứa các lỗi hệ thống hiện tại. Các lỗi được giữ lại khi mất MQTT và được gửi lại trong snapshot/telemetry sau khi kết nối phục hồi. Mã lỗi mức cảnh báo gồm mất mạng/broker, Modbus, cảm biến ngoài phạm vi và lỗi ngõ ra tải; lỗi nghiêm trọng gồm NVM, khởi tạo Ethernet/phần cứng, khởi tạo subsystem/task và cấp phát tài nguyên. Danh sách mã gồm `SYS_ERR_MODBUS_TIMEOUT`, `SYS_ERR_NET_LOST`, `SYS_ERR_MQTT_BROKER`, `SYS_ERR_NVM_FAIL`, `SYS_ERR_SENSOR_OUT_RANGE`, `SYS_ERR_ETH_INIT`, `SYS_ERR_INIT_FAILURE`, `SYS_ERR_RESOURCE_ALLOC` và `SYS_ERR_LOAD_OUTPUT_DO1`..`SYS_ERR_LOAD_OUTPUT_DO4`.

### 4.2. LWT
bản tin này được broker tự pubish khi esp mất kết nối mqtt. app đọc bản tin này để đồng bộ trạng thái thiết bị (online/offline) để hiển thị
```json
{
  "v": 1,
  "type": "LWT",
  "state": "offline",
  "boot_id": "361d7646",
  "ts": 1791854906000
}
```

## 5. Topic: `telemetry` (ESP32 ➔ App)

Gửi định kỳ một bản tin telemetry mỗi chu kỳ lấy mẫu, kể cả khi không có cảm biến nào đang bật. Khi đó `input` là mảng rỗng; app vẫn dùng `net_interface` (cùng tên field với bản tin `SNAPSHOT`) để cập nhật trạng thái kết nối mạng. Chỉ các cảm biến đã cấu hình và đang bật mới có mặt trong `input`:
```json
{
  "v": 1,
  "seq": 142,
  "boot_id": "361d7646",
  "uptime_ms": 3600000,
  "buffered": false,
  "net_interface": "WIFI",
  "ts": 1791854906000,
  "input": [
    {
      "interface_type": "rs485",
      "port_id": "RS1",
      "name": "Nhiệt độ & Độ ẩm",
      "valid": true,
      "values" [
        {
          "name": "Nhiệt độ",
          "unit": "°C",
          "value": 25.1
        },
        {
          "name": "Độ ẩm",
          "unit": "%RH",
          "value": 60
        },
      ]
    },
    {
      "interface_type": "rs485",
      "port_id": "RS2",
      "name": "Oxy hòa tan",
      "valid": true,
      "values" [
        {
          "name": "Nồng độ oxy hòa tan",
          "unit": "mg/L",
          "value": 25.1
        },
        {
          "name": "Nhiệt độ",
          "unit": "°C",
          "value": 25
        },
        {
          "name": "Độ bão hòa",
          "unit": "%",
          "value": 92.4
        }
      ]
    },
    {
      "interface_type": "rs485",
      "port_id": "RS3",
      "name": "Cảm biến pH",
      "valid": true,
       "values" 
       [
        {
          "name": "Độ pH",
          "unit": "%",
          "value": 7
        },
       ]
    },
  ],
  "errors": {
    "code_mask": 0,
    "messages": []
  }
}
```
* **`net_interface`**: `"WIFI"` hoặc `"ETH"` (dùng chung tên với `SNAPSHOT`).
* **`unit`**: Đơn vị đo do ESP32 tự định nghĩa và gửi lên App để hiển thị giao diện.

---

## 6. Quy ước triển khai (đã chốt giữa ESP32 và Flutter)

Các mục dưới đây làm rõ những chỗ tài liệu còn mơ hồ. ESP32 và App đều triển khai theo đúng các quy ước này.

### 6.1. Topic
* ESP32 **chỉ subscribe `commands`**. Không còn topic `config/set`; mọi cấu hình đều đi qua `commands`.
* ESP32 publish `ack` (QoS 1), `status` (QoS 1, snapshot là retained), `telemetry` (QoS 0).
* App subscribe `ack`, `status`, `telemetry`; publish `commands` (QoS 1, không retained).

### 6.2. Nhận diện lệnh
* Tên lệnh luôn nằm ở trường `type` (kiểu chuỗi), kể cả `GET_STATUS`, `GET_TELEMETRY` và `EMERGENCY_STOP`.
* Trường `action` chỉ là tham số kiểu `bool` (`SET_LOAD_STATE`, `SENSOR_CONFIG`, `TOGGLE_*`), không bao giờ là tên lệnh.
* `SET_LOAD_DELAY`: sau `delay_min` phút tải chuyển sang trạng thái của pha 1; nếu `duration` = 0 thì tải giữ nguyên trạng thái đó mãi mãi (không có pha 2, hẹn giờ kết thúc); nếu `duration` > 0 thì sau `duration` phút tải đảo trạng thái.
* Mục 2.10 dùng tên lệnh `ADD_LOAD_SCHEDULER`.
* Định danh cổng: `load_id` = `DO1..DO4`; `sensor_id` = `RS1..RS4`, `AN1`, `DI1..DI4`; `condition_id` = `CON1..CON2`; `scheduler_id` = `SHE1..SHE3`.
* `interface_type`: `rs485` | `analog_4_20ma` | `di`. Cảm biến DI và analog không có `slave_id`.
* `SENSOR_CONFIG.action`: `true` = thêm (lỗi `CONFLICT` nếu cổng đã có cảm biến), `false` = sửa (lỗi `INVALID_VALUE` nếu cổng chưa có cảm biến).
* `SET_LOAD_CONDITION` / `SET_LOAD_SCHEDULE` chỉ sửa điều kiện / lịch hẹn đã được `ADD_*`; chưa tồn tại thì `INVALID_VALUE`. `ADD_*` trùng id thì `CONFLICT`.
* Giá trị mặc định sau `ADD_LOAD_CONDITION`: `condition_enabled=false`, `action=false`, `operator=false`, `threshold=0`, `sensor_id=""` (chưa chọn). Sau `ADD_LOAD_SCHEDULER`: `scheduler_enabled=false`, `days_mask=0`, `on_time_utc="00:00"`, `off_time_utc="00:00"`.
* Giới hạn: tối đa 2 điều kiện và 3 lịch hẹn mỗi tải. Điều kiện dùng `sensor_id` là cảm biến đã được cấu hình (RS*, AN1, DI*). Cảm biến DI có giá trị `true` = 1, `false` = 0 khi so sánh với `threshold`.
* `name` (tải, cảm biến, thiết bị): 1..31 byte UTF-8, không có khoảng trắng đầu/cuối. App phải gửi payload `commands` dưới dạng UTF-8 để tên có dấu hợp lệ.
* Tên mặc định của thiết bị là `PROV_ESP32_` + 6 ký tự hex cuối của MAC Bluetooth (trùng tên quảng bá BLE), ví dụ `PROV_ESP32_A1B2C3`. App lấy `device_name` trong snapshot đầu tiên làm tên ban đầu khi thêm thiết bị.

### 6.3. ACK
* Mỗi lệnh hợp lệ về cú pháp đều nhận đúng 1 ACK sau khi ESP32 đã **áp dụng xong** (và đã lưu NVM nếu lệnh được lưu NVM).
* Trường bổ sung (không bắt buộc đọc): `cmd` = tên lệnh đã xử lý.
* `result`: `ok` | `error`. `code`: `OK`, `INVALID_JSON`, `INVALID_FIELDS`, `INVALID_VALUE`, `UNSUPPORTED_ACTION`, `UNSUPPORTED_VERSION`, `FORBIDDEN`, `CONFLICT`, `EXPIRED`, `BUSY`, `STORAGE_ERROR`, `INTERNAL_ERROR`.
* Lệnh `cmd_id` trùng lặp (gửi lại) nhận lại ACK cũ với `dup=true`, không thực thi lại.
* Sau mỗi lệnh thành công ESP32 publish ngay một snapshot retained mới (ngay sau ACK). App chỉ cập nhật giao diện khi nhận ACK `ok` và đồng bộ lại theo snapshot.
* Nếu ACK lỗi, App hiển thị `code` và `reason`.

### 6.4. Độ ưu tiên (cao -> thấp)
1. `EMERGENCY_STOP`: tắt mọi tải (output = 0), xóa hẹn giờ trễ / điều kiện / lịch hẹn của mọi tải và vô hiệu hóa (disable) **tất cả cảm biến** (ngừng đọc). Các tải **không** bị vô hiệu hóa (`enabled` giữ nguyên). Không có lệnh hủy dừng khẩn cấp: người dùng bật lại từng cảm biến (`TOGGLE_SENSOR_CAPABILITY`) và cấu hình lại điều kiện / lịch hẹn khi cần; tải vẫn điều khiển thủ công được ngay. Trạng thái disable cảm biến và việc xóa cấu hình được lưu NVM.
2. Tải bị disable (`enabled=false`): output luôn tắt, mọi lệnh khiến tải bật bị từ chối (`INVALID_VALUE`, reason `load is disabled`). Disable một tải = tắt output, dừng hẹn giờ trễ và **xóa** mọi điều kiện / lịch hẹn của tải đó (`load_condition` và `load_scheduler` trong snapshot rỗng). Enable lại không khôi phục cấu hình cũ, tải ở trạng thái tắt. Khi tải đang disable, `ADD_*`, `SET_*` và `TOGGLE_*` của điều kiện / lịch hẹn bị từ chối (`INVALID_VALUE`, reason `load is disabled`); `SET_LOAD_NAME` vẫn được phép.
3. `SET_LOAD_STATE` (thủ công) và nút momentary vật lý `ONx_`/`OFFx_` có cùng mức ưu tiên; lệnh mới nhất thắng. `SET_LOAD_STATE` hoặc nút vật lý thực hiện ngay, dừng hẹn giờ trễ và vô hiệu hóa (condition_enabled / scheduler_enabled = false) mọi điều kiện và lịch hẹn của tải đó. Không lưu trạng thái tải vào NVM (khởi động lại tải luôn tắt). DI enabled tên `ON1_...` .. `ON4_...` và `OFF1_...` .. `OFF4_...` gắn vào tải cùng số. Cạnh nhấn active-low được nhận bằng GPIO falling-edge interrupt và debounce 40 ms; nhấn ON bật, nhấn OFF tắt, nhả nút không phát lệnh.
4. `SET_LOAD_DELAY` (hẹn giờ trễ, một lần): khi đang chạy thì điều kiện cảm biến và lịch hẹn của tải đó tạm dừng; hết hẹn giờ thì chúng hoạt động lại. Lệnh mới thay thế hẹn giờ cũ. `STOP_LOAD_DELAY` dừng ngay và giữ nguyên trạng thái hiện tại của tải.
5. Điều kiện cảm biến (tính theo mức, đánh giá mỗi lần có dữ liệu cảm biến mới, mỗi 2 giây). Nếu nhiều điều kiện cùng thỏa mãn thì điều kiện có `action=false` (tắt) thắng. Cảm biến lỗi / bị disable thì điều kiện không được đánh giá (giữ nguyên trạng thái tải).
6. Lịch hẹn (theo cạnh): đúng phút `on_time_utc` / `off_time_utc` và đúng thứ trong `days_mask` thì bật / tắt. Riêng lệnh tắt cũng được thực hiện vào ngày kế tiếp nếu chính lịch hẹn đó đã bật tải (lịch qua nửa đêm). Cần ESP32 đã đồng bộ giờ (SNTP); chưa có giờ thì lịch hẹn không chạy.

Khi điều kiện và lịch hẹn cùng bật, điều kiện cảm biến được ưu tiên hơn lịch hẹn: nếu có điều kiện đang thỏa mãn thì lệnh bật / tắt của lịch hẹn bị bỏ qua.

### 6.5. Cảm biến
* Cảm biến bị disable (hoặc chưa cấu hình) **không được đọc**, không xuất hiện trong `telemetry`. Enable lại thì ESP32 đọc lại ngay ở chu kỳ kế tiếp.
* DI tên `ON1_...` .. `ON4_...` hoặc `OFF1_...` .. `OFF4_...` là nút momentary điều khiển tải theo mục 6.4; đổi tên bỏ tiền tố hoặc disable DI thì input không còn điều khiển tải. DI này bị ẩn khỏi danh sách vận hành/diagnostics của app nhưng vẫn chỉnh sửa được trong quản lý cảm biến.
* `DELETE_SENSOR` đồng thời vô hiệu hóa mọi điều kiện đang dùng cảm biến đó.
* Mỗi cổng RS485 có model cố định theo firmware (RS1: SHT40, RS2: DO, RS3: pH, RS4: DO); `name` chỉ là nhãn. Cổng analog chưa có phần cứng đọc: cho phép cấu hình nhưng `valid=false`.
* Telemetry của `di` có `values: [{"name":"Trạng thái","unit":"","value":true}]` (kiểu `bool`).

### 6.6. Snapshot bổ sung
* `load_delay` luôn có mặt, thêm các trường: `active` (bool), `phase` (`IDLE` | `WAIT_FIRST` | `WAIT_SECOND`), `remaining_s` (giây còn lại đến lần đổi trạng thái tiếp theo của hẹn giờ; 0 khi không chạy). Trường `start_time` (UTC `HH:MM`) chỉ có khi ESP32 đã có giờ.
* `load_condition` / `load_scheduler` chỉ liệt kê các mục đã `ADD`. `sensor_id` của điều kiện chưa chọn là `""`.
* `input` chỉ liệt kê cảm biến đã cấu hình (kể cả đang disable), `valid` là kết quả đọc gần nhất.
* `runtime_interfaces.*_used` = số cảm biến đã cấu hình; `loads_used` = số tải đang `enabled`.
* `emergency.active` = `true` kể từ lúc `EMERGENCY_STOP` cho đến khi người dùng bật lại một cảm biến (không lưu NVM).
* Snapshot được publish: khi MQTT online, định kỳ (60 s), ngay sau mỗi lệnh thành công ngoại trừ `GET_TELEMETRY`, khi `GET_STATUS`, và khi trạng thái tải đổi (bật/tắt do lịch hẹn, điều kiện, hẹn giờ trễ). `GET_TELEMETRY` publish mẫu cảm biến mới nhất ngay lên topic `telemetry`.

### 6.7. Đồng bộ thời gian / đếm ngược
* ESP32 đồng bộ giờ bằng SNTP. Mọi mốc thời gian (`ts`, `on_time_utc`, `start_time`) là UTC.
* Đếm ngược hẹn giờ trễ chạy trên ESP32 (đồng hồ đơn điệu). App hiển thị đếm ngược từ `remaining_s` của snapshot cộng thời điểm App nhận snapshot, và tự hiệu chỉnh mỗi lần nhận snapshot mới (retained snapshot khi kết nối lại, `GET_STATUS`, snapshot sau mỗi lần đổi pha).
* Khi hết một pha, ESP32 tự đổi trạng thái tải và publish snapshot mới.

### 6.8. Log
* ESP32 in log mức INFO cho mọi lệnh: `CMD rx type=... cmd_id=...`, `CMD ok ...` hoặc `CMD err ... code=... reason=...`, và `ACK tx ...`.
* App ghi log tương ứng: `[MQTT] TX cmd ...`, `[MQTT] RX ack ...`, `[MQTT] RX snapshot ...`.
