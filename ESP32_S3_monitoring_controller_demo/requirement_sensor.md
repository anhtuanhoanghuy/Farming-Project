# Yêu cầu Kỹ thuật Triển khai Mô-đun Đọc Cảm biến RS485 (Oxy, pH, SHT40)

Tài liệu này cung cấp các yêu cầu chi tiết dành cho AI/Developer để xây dựng mô-đun phần mềm đọc dữ liệu từ 3 loại cảm biến chuẩn truyền thông **RS485 / Modbus RTU**: 
1. Cảm biến Oxy hòa tan (Dissolved Oxygen - DO)
2. Cảm biến độ pH (pH Sensor)
3. Cảm biến Nhiệt độ & Độ ẩm (SHT40 tích hợp RS485 transmitter)

---

## 1. Mục tiêu & Kiến trúc Tổng quan

- **Mục tiêu:** Xây dựng mô-đun phần mềm độc lập (Service / Task / Thread) thực hiện việc đọc dữ liệu định kỳ từ 3 cảm biến trên bus RS485, đảm bảo tính ổn định cao, phát hiện lỗi kịp thời và tự phục hồi khi có sự cố mạng/phần cứng.
- **Phương thức giao tiếp:** Đơn công bán song lập (Half-Duplex) qua RS485 với giao thức Modbus RTU.
- **Mô hình đọc:** Đọc tuần tự từng cảm biến (Polling Mode) tránh xung đột bus (Bus Collision).

---

## 2. Thông số Truyền thông Kỹ thuật (Communication Setup)

| Thông số | Giá trị cấu hình mặc định | Có thể tùy biến (Configurable) |
| :--- | :--- | :--- |
| **Baud Rate** | `4800 bps` | Không (cố định trong firmware) |
| **Data Bits** | `8` | Không |
| **Parity** | `None` (N) | Không |
| **Stop Bits** | `1` | Không |
| **Timeout (Đợi phản hồi, mỗi request/retry)** | `200 ms` | Không |
| **Inter-frame Delay** | `50 ms` (Thời gian nghỉ giữa các slot) | Không |

---

## 3. Cấu hình Cảm biến & Bản đồ Thanh ghi (Register Mapping)

Ánh xạ thanh ghi cố định theo loại cảm biến trong firmware; NVS chỉ cấu hình `slave_id`, `sensor_type`, `name` và `enabled`. Đọc Holding Register dùng Function Code `0x03`; đọc Input Register dùng Function Code `0x04`.

### 3.1. Cảm biến Oxy Hòa tan (Dissolved Oxygen - DO)
- **Slave ID mặc định:** theo slot cấu hình NVS.
- **Thanh ghi & Định dạng** (theo bảng register của transmitter DO được cung cấp):
  - Đọc Holding Register bằng Function `0x03`, bắt đầu tại `0x0000`, tổng cộng 6 registers (`0x0000`–`0x0005`).
  - `0x0000`–`0x0001`: DO saturation (%), IEEE-754 Float32, big-endian.
  - `0x0002`–`0x0003`: DO concentration (mg/L), IEEE-754 Float32, big-endian.
  - `0x0004`–`0x0005`: nhiệt độ (°C), IEEE-754 Float32, big-endian.
  - Dải hợp lệ theo manual: concentration `0–20 mg/L`, saturation `0–200%`.
  - Firmware ánh xạ `v1=concentration`, `v2=temperature`, `v3=saturation`; giá trị không hữu hạn hoặc ngoài dải vật lý bị đánh dấu `out_of_range`.

### 3.2. Cảm biến pH
- **Slave ID mặc định:** theo slot cấu hình NVS.
- **Thanh ghi & Định dạng** (theo bảng register của transmitter pH được cung cấp):
  - Đọc Holding Register bằng Function `0x03`, bắt đầu tại `0x0000`, đọc 2 registers.
  - `0x0000`: pH, `Uint16 / 100`.
  - `0x0001`: nhiệt độ, `Int16 / 10` °C.
  - Dải đo theo manual: pH `0–14`, nhiệt độ `0–60 °C`; dữ liệu ngoài dải bị đánh dấu `out_of_range`.
  - Firmware ánh xạ `v1=pH`, `v2=temperature`.

### 3.3. Cảm biến SHT40 (Nhiệt độ & Độ ẩm môi trường)
- **Slave ID mặc định:** theo slot cấu hình NVS.
- **Thanh ghi & Định dạng** (theo bảng register SHT40 RS485 được cung cấp):
  - Theo `resources/sht40.pdf` (trang 5, 7), Function `0x03`, bắt đầu tại Holding Register `0x0000`, đọc 2 registers (`0x0000`–`0x0001`).
  - Register đầu là `Uint16 / 10` cho độ ẩm %RH; register kế là `Int16 / 10` cho nhiệt độ °C.
  - Kiểm tra nhiệt độ trong phạm vi làm việc `−40–60 °C`, độ ẩm `0–100 %RH`.
  - Transmitter mặc định 4800 baud, địa chỉ 1; khớp với bus firmware 4800 baud (8N1).
  - Khi lưu cấu hình RS485 với ID khác ID đang lưu, firmware ghi địa chỉ mới vào thanh ghi `0x07D0` bằng Function `0x06` và chỉ cập nhật NVM sau khi cảm biến xác nhận. Khi thêm mới, firmware giả định cảm biến đang ở ID mặc định `1`.
  - Trên app, ID gợi ý khi thêm mới là `100 + số cổng` (RS1=`101` ... RS4=`104`); màn hình chỉ đóng sau ACK thành công.
  - Vì các transmitter DO/pH và SHT40 đều có thể xuất xưởng với ID `1`, chỉ đổi ID khi cảm biến có địa chỉ cũ duy nhất trên bus. Nếu chưa cấu hình được ID khác, cô lập cảm biến khỏi các thiết bị khác trước khi lưu.

---

## 4. Cơ chế Đọc Dữ liệu (Polling Workflow)

1. **Vòng lặp đọc định kỳ (Cycle Loop):**
   - Đọc lần lượt: **Sensor Oxy** $\rightarrow$ *(Nghỉ Inter-frame)* $\rightarrow$ **Sensor pH** $\rightarrow$ *(Nghỉ Inter-frame)* $\rightarrow$ **Sensor SHT40**.
   - Chu kỳ toàn bộ vòng lặp (Poll Interval): `5000 ms` (5 giây), tính từ lúc bắt đầu chu kỳ này đến lúc bắt đầu chu kỳ sau. Nếu đọc lâu hơn 5 giây (timeout/retry), chu kỳ sau bắt đầu ngay.

2. **Quy trình gửi request:**
   - Tạo khung tin Modbus RTU (Slave ID + Function Code + Register Address + Data Length + CRC16).
   - Bật chân điều khiển chiều RS485 (DE/RE pin) nếu phần cứng yêu cầu (hoặc tự động ở cấp Transceiver).
   - Gửi dữ liệu $\rightarrow$ Chờ phản hồi trong khoảng `Timeout`.
   - Đọc response $\rightarrow$ Kiểm tra CRC16 $\rightarrow$ Parse dữ liệu $\rightarrow$ Đưa vào Bộ đệm dữ liệu (Data Buffer).

---

## 5. Cơ chế Báo lỗi & Quản lý Sự cố (Error Handling & Fault Tolerance)

Để đảm bảo hệ thống chạy 24/7 không rơi vào trạng thái treo (deadlock), cần bắt buộc triển khai các cơ chế sau:

### 5.1. Phân loại Lỗi & Trạng thái Cảm biến
Cần gán cho mỗi cảm biến một trạng thái hoạt động (`SensorStatus`):
- `STATUS_OK`: Đọc thành công, dữ liệu hợp lệ.
- `ERROR_TIMEOUT`: Cảm biến không phản hồi trong thời gian chờ.
- `ERROR_CRC`: Dữ liệu nhận được bị lỗi Checksum/CRC16.
- `ERROR_MODBUS_EXCEPTION`: Cảm biến trả về mã lỗi Modbus (Ví dụ: `0x83` - Illegal Address).
- `ERROR_OUT_OF_RANGE`: Giá trị đo vượt ngưỡng vật lý logic.
- `STATUS_OFFLINE`: Cảm biến bị mất kết nối kéo dài.

### 5.2. Thuật toán Thử lại (Retry Mechanism)
- Khi gặp lỗi đọc (`TIMEOUT` hoặc `CRC`), **KHÔNG** đánh giá cảm biến hỏng ngay lập tức.
- Thực hiện **Thử lại (Retry)** tối đa `3 lần` liên tiếp.
- Giữa các lần Retry, cần có khoảng trễ ngắn (firmware dùng `50 ms`).
- Nếu sau 3 lần vẫn lỗi:
  - Đánh dấu `valid=0` và mã lỗi `timeout`/`crc`/`protocol` cho cycle đó.
  - Tăng `consecutive_fail_count` (đếm theo cycle 5 s, không đếm theo retry).
  - Chuyển sang đọc cảm biến tiếp theo trên bus (không dừng toàn bộ tiến trình).
- **Hybrid Circuit Breaker**: khi `consecutive_fail_count ≥ 5` (~25 s) sensor chuyển `OFFLINE`; xem 5.3.

### 5.3. Cơ chế Đánh giá Offline & Tự Phục hồi (Self-Healing)
- **Mất kết nối kéo dài (Sensor Offline):**
  - Nếu `consecutive_fail_count >= 5` (liên tiếp 5 chu kỳ không đọc được, ~25 s):
    - Đổi trạng thái cảm biến thành `OFFLINE` và set `SYS_ERR_MODBUS_TIMEOUT`.
    - Khi OFFLINE **không gửi frame**; mỗi cycle vẫn phát slot `valid=false`, `error="offline"` (mã 10) trong telemetry.
    - Probe lại mỗi 60 giây, hoặc ngay khi có cấu hình mới/đổi Slave ID, để không làm nghẽn bus RS485 của các cảm biến khác.
- **Phục hồi kết nối (Auto Recovery):**
  - Probe thành công $\rightarrow$ reset `consecutive_fail_count = 0`, về `ONLINE` và chu kỳ 5 s tiêu chuẩn. Khi mọi sensor enabled đều ONLINE thì xóa `SYS_ERR_MODBUS_TIMEOUT`.

### 5.4. Xử lý Lỗi Cổng nối tiếp (Serial Port Failure)
- Nếu cổng Com / TTY bị đứt kết nối (USB to RS485 bị rút ra):
  - Bắt ngoại lệ ở mức System/Driver.
  - Tiến hành thử đóng cổng (`close()`) và mở lại cổng (`re-open()`) định kỳ mỗi `5 giây`.
  - Phát sự kiện cảnh báo hệ thống `HARDWARE_BUS_DISCONNECTED`.

---

## 6. Kiểm tra Hợp lệ Dữ liệu (Data Validation Rules)

Mô-đun phải lọc các giá trị dị biệt (Spike/Outlier) do nhiễu điện từ bằng các quy tắc vật lý:

| Cảm biến | Dải giá trị Hợp lệ (Valid Range) | Xử lý khi Out-of-Range |
| :--- | :--- | :--- |
| **pH** | $pH \in [0.0, 14.0]$ | Bỏ qua mẫu, gắn cờ `ERROR_OUT_OF_RANGE` |
| **Nhiệt độ pH** | $T \in [0.0, 60.0] ^\circ\text{C}$ | Bỏ qua mẫu, gắn cờ `ERROR_OUT_OF_RANGE` |
| **Oxy hòa tan (DO)** | $DO \in [0.0, 20.0] \text{ mg/L}$; saturation $\in [0, 200]\%$ | Bỏ qua mẫu, gắn cờ `ERROR_OUT_OF_RANGE` |
| **Nhiệt độ (SHT40 / Probe)** | $T \in [-20.0, 80.0] ^\circ\text{C}$ | Bỏ qua mẫu, gắn cờ `ERROR_OUT_OF_RANGE` |
| **Độ ẩm (SHT40)** | $RH \in [0.0, 100.0] \%$ | Bỏ qua mẫu, gắn cờ `ERROR_OUT_OF_RANGE` |

---

## 7. Định dạng Dữ liệu Đầu ra (Output Payload Standard)

Khi đọc xong 1 chu kỳ, mô-đun cần xuất ra cấu trúc dữ liệu chuẩn JSON (hoặc struct/object tương đương) bao gồm đầy đủ dữ liệu và trạng thái sức khỏe cảm biến:

```json
{
  "timestamp": "2026-10-08T21:00:00Z",
  "bus_status": "CONNECTED",
  "data": {
    "dissolved_oxygen": {
      "value_mg_l": 6.85,
      "temperature_c": 27.5,
      "saturation_pct": 96.2,
      "status": "STATUS_OK",
      "error_code": 0
    },
    "ph": {
      "value": 7.2,
      "temperature_c": 27.4,
      "status": "STATUS_OK",
      "error_code": 0
    },
    "sht40": {
      "temperature_c": 31.2,
      "humidity_rh": 68.5,
      "status": "ERROR_TIMEOUT",
      "error_code": 404
    }
  }
}
```

### 7.1 Tích hợp với contract firmware và điều khiển tải theo cảm biến

- JSON lồng nhau ở ví dụ trên chỉ minh họa dữ liệu đo. Firmware gửi `sensor_cycle_t` qua queue; contract MQTT thực tế là `sensors[]` theo [`json_payoad.md`](json_payoad.md), không publish nguyên JSON `data` ở trên.
- ID được suy ra ổn định từ slot, không phải trường lưu trong `sensor_sample_t`: `sensor_001`…`sensor_004` là RS485 `interface_index` 0…3; `sensor_005` là analog `interface_index` 0. Telemetry và snapshot phải xuất ID này cùng sensor.
- Rule điều khiển tải dùng giá trị chính `v1`: DO=`do_mg_l` (mg/L), pH=`ph_val`, SHT40=`temp` (°C); với SHT40, `v2` là độ ẩm (%RH) nhưng hiện không được chọn làm giá trị cho rule tải.
- Chỉ sample mới có `valid=1` và giá trị hữu hạn được dùng để so sánh. Nếu sample của sensor được rule tham chiếu bị thiếu, invalid hoặc không hữu hạn, tải liên quan phải về OFF; sample lỗi vẫn được phát riêng với mã lỗi chuẩn, không làm gián đoạn các sensor khác.
- Cấu hình rule bật/tắt tải không thuộc `config.json` của sensor module: app gửi full-replace `config/set` `type=load_control`; firmware lưu cùng policy tải trong NVS. Lịch tuần và rule cảm biến không bật đồng thời. Xem [`requirement_loads.md`](requirement_loads.md) mục LC-SEN và [`json_payoad.md`](json_payoad.md) mục 1.
- Slot bị disable vẫn có trong `sensor_cycle_t` với `valid=0`, `error=disabled`; slot enabled bị timeout/CRC được retry tối đa 3 lần, mỗi lần chờ phản hồi tối đa 200 ms; sau 5 cycle lỗi liên tiếp slot chuyển OFFLINE (`error=offline`, mục 5.3).

---

## 8. Cấu trúc Tệp Cấu hình (Configuration File - `config.json`)

`config.json` dưới đây mô tả tham số polling minh họa. Bản firmware ESP-IDF lưu cấu hình sensor trong `app_config_t`/NVS và nhận cập nhật qua MQTT theo `requirement_mqtt.md`; không đọc trực tiếp file JSON này.

Triển khai file cấu hình để không cứng mã nguồn (hard-code):

```json
{
  "serial": {
    "port": "/dev/ttyUSB0",
    "baudrate": 4800,
    "parity": "N",
    "stopbits": 1,
    "timeout_ms": 200
  },
  "polling": {
    "interval_ms": 2000,
    "inter_sensor_delay_ms": 50,
    "max_retries": 3
  },
  "sensors": [
    {
      "name": "dissolved_oxygen",
      "slave_id": 1,
      "enabled": true,
      "registers": {
        "do_val": 0,
        "temp_val": 2
      }
    },
    {
      "name": "ph",
      "slave_id": 2,
      "enabled": true,
      "registers": {
        "ph_val": 0,
        "temp_val": 1
      }
    },
    {
      "name": "sht40",
      "slave_id": 3,
      "enabled": true,
      "registers": {
        "temp_val": 0,
        "humi_val": 1
      }
    }
  ]
}
```

---

## 9. Yêu cầu Chế độ Mô phỏng & Logging (Mocking & Logging)

1. **Chế độ Mock (Simulator Mode):**
   - Cho phép bật cờ `ENABLE_MOCK = true` trong config để chạy test giao diện/logic khi không có phần cứng RS485 thực tế.
   - Hàm Mock tự tạo dữ liệu biến thiên ngẫu nhiên theo mô hình hình sin cho pH ($6.5 \rightarrow 8.5$), DO ($5.0 \rightarrow 8.0 \text{ mg/L}$), Nhiệt độ ($25 \rightarrow 35 ^\circ\text{C}$).

2. **Ghi Log (Logging):**
   - **Console / Log File:**
     - `INFO`: Thông số đọc thành công từng chu kỳ.
     - `WARN`: Cảnh báo khi bị retry hoặc giá trị chập chờn.
     - `ERROR`: Lỗi Timeout, CRC, mất kết nối cảm biến.
   - Cần có cơ chế Tự xoá log cũ (Log rotation) để tránh tràn bộ nhớ đệm (với thiết bị IoT nhúng).

---

## 10. Tiêu chí Nghiệm thu (Acceptance Criteria cho AI/Dev)

- [ ] Chương trình đọc thành công cả 3 cảm biến trên cùng 1 đường truyền RS485 mà không bị xung đột dữ liệu.
- [ ] Khi rút jack kết nối của 1 cảm biến ngẫu nhiên, 2 cảm biến còn lại vẫn tiếp tục hoạt động bình thường. Cảm biến bị rút báo trạng thái `ERROR_TIMEOUT` hoặc `STATUS_OFFLINE`.
- [ ] Khi cắm lại cảm biến bị rút, hệ thống tự động phục hồi kết nối và đọc lại dữ liệu bình thường mà không cần khởi động lại phần mềm.
- [ ] Tính toán chính xác CRC16 Modbus RTU và chuyển đổi đúng kiểu dữ liệu từ Register sang dạng số thực (Float/Int thập phân).
- [ ] Đạt thời gian phản hồi theo đúng chu kỳ cấu hình.

Dưới đây là **Prompt chuyên dụng** được lưu từ yêu cầu ban đầu. Contract triển khai hiện tại trong các mục 2–7 và `components/app_modbus` là nguồn chính khi có khác biệt về register mapping, chữ ký API hoặc mã lỗi.

---

### 📋 Prompt copy cho AI Code:

```markdown
Bạn là một Chuyên gia Lập trình Firmware Embedded Systems (ESP-IDF v5.2+, FreeRTOS, ESP32-S3). Hãy viết mã nguồn C hoàn chỉnh cho component `app_modbus` thuộc dự án "Aquaculture Pond Monitoring Controller".

### 1. Mục tiêu công việc
Implement module `components/app_modbus` (bao gồm `app_modbus.h` và `app_modbus.c`) để đọc 3 loại cảm biến Modbus RTU RS485 qua UART (có chân DE/RE điều khiển hướng TX/RX):
1. **SHT40 (Nhiệt độ & Độ ẩm)**: Đọc Input Registers `0x0001`–`0x0002` (Function `0x04`).
2. **Oxy hòa tan (DO)**: Đọc Float32 big-endian từ Holding Registers `0x0002`–`0x0003` (Function `0x03`).
3. **pH**: Đọc giá trị pH (Holding Register `0x0000`).

---

### 2. Yêu cầu Kiến trúc & Quy chuẩn Đột phá

#### A. Cấu trúc Dữ liệu & Khai báo (`main_data_types.h` / `app_modbus.h`)
Sử dụng các kiểu dữ liệu thống nhất của hệ thống:
- Cấu hình từng sensor: `modbus_sensor_cfg_t` (chứa `slave_id`, `sensor_type`, `name`, `enabled`).
- Đầu ra chu kỳ đọc: `sensor_cycle_t` chứa mảng các `sensor_sample_t`:
  ```c
  typedef struct {
      uint8_t interface_type;  /* SENSOR_INTERFACE_RS485 */
      uint8_t interface_index; /* 0..3 */
      uint8_t sensor_type;     /* SENSOR_SHT40, SENSOR_DO, SENSOR_PH */
      uint8_t valid;           /* 1 nếu thành công, 0 nếu lỗi */
      uint8_t error;           /* 0=None, 1=Timeout, 2=CRC, 3=Range, 4=Not ready, 5=Disabled mid-cycle, 6=Stopped, 7=Disabled, 8=Modbus exception, 9=Protocol, 10=Offline */
      float v1, v2;            /* SHT40: v1=Temp, v2=Humid; DO: v1=mg/L; pH: v1=pH */
  } sensor_sample_t;

```

#### B. Điều khiển Cơ chế UART RS485

* Khởi tạo UART Driver (UART_NUM_1 hoặc cấu hình từ Kconfig/defines), baudrate 4800, 8N1.
* Cấu hình chân `UART_MODE_RS485_HALF_DUPLEX`, tự động điều khiển chân DE/RE via RTS pin (hoặc toggle GPIO bằng tay trước/sau khi gửi nếu dùng GPIO thường).
* Sử dụng Mutex `modbus_uart_mutex` bảo vệ tài nguyên UART chống race condition.

#### C. Logic Polling Engine & Khôi phục Lỗi (Fault Tolerance)

1. **Cô lập lỗi từng cảm biến (Isolation)**: Nếu 1 cảm biến bị đứt dây/lỗi Timeout/CRC, **KHÔNG** làm gián đoạn việc đọc các cảm biến còn lại. Cảm biến lỗi đánh dấu `valid = 0` và gán mã `error` tương ứng.
2. **Cơ chế Thử lại (Retry)**: Mỗi cảm biến được retry tối đa **3 lần** trước khi kết luận lỗi.
3. **Tính toán CRC16**: Viết/sử dụng hàm kiểm tra CRC16 Modbus RTU chuẩn xác cho cả frame gửi và nhận.
4. **Cảnh báo Lỗi Hệ thống**:
* Nếu có ít nhất 1 cảm biến enabled ở trạng thái OFFLINE (≥ 5 cycle lỗi liên tiếp), kích hoạt bit `SYS_ERR_MODBUS_TIMEOUT` trong `sys_error_mask` (qua API của `app_sysmon`).
* Nếu tất cả cảm biến enabled đều ONLINE, XÓA bit `SYS_ERR_MODBUS_TIMEOUT`.


5. **Hiệu chỉnh (Calibration Offset)**:



#### D. Tích hợp FreeRTOS Task

* Tạo `sensor_acquisition_task` (Core 1, Priority 5, Stack 4096).
* Vòng lặp `for(;;)` thực hiện:
* Gọi `esp_task_wdt_reset()` để feed Task Watchdog (TWDT).
* Quét qua danh sách các RS485 interface được `enabled`.
* Thực thi đọc dữ liệu, tính offset, tạo `sensor_cycle_t`.
* Đẩy `sensor_cycle_t` vào `sensor_data_queue` (không block task nếu queue đầy, dùng drop-oldest hoặc timeout 0).
* Chờ phần còn lại của chu kỳ 5 giây (tính từ lúc bắt đầu đọc), có thể bị đánh thức sớm khi cấu hình thay đổi.



---

### 3. Yêu cầu Đầu ra Code

Hãy viết đầy đủ nội dung cho 2 file:

1. **`components/app_modbus/include/app_modbus.h`**:
* Khai báo các API công khai: `app_modbus_init(const app_config_t *)`, `app_modbus_read_sensor(uint8_t, sensor_sample_t *)`, `app_modbus_start_task()`, `app_modbus_update_config(const app_config_t *)`, `app_modbus_suspend()` và `app_modbus_resume()`.
* Các định nghĩa Register Address và Function Code cho SHT40, DO (Reg 0x0002–0x0003), pH (Reg 0x0000).


2. **`components/app_modbus/app_modbus.c`**:
* Khai báo đầy đủ include (ESP-IDF, FreeRTOS, UART, Log, Driver).
* Hàm tính CRC16 Modbus RTU.
* Hàm tạo Modbus Request Frame & Parse Response Frame.
* Task `sensor_acquisition_task` hoàn chỉnh.
* Xử lý Thread-safety với Mutex.



Yêu cầu code chuẩn C11 / ESP-IDF v5.2+, viết rõ ràng, có comment giải thích bằng tiếng Việt, đầy đủ log lỗi (`ESP_LOGE`, `ESP_LOGW`, `ESP_LOGI`), không để lại code mẫu giả lập (placeholders).

```

---