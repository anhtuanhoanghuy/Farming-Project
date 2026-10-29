# ĐẶC TẢ YÊU CẦU KỸ THUẬT: USER RESET BUTTON (SOFT-RESET)

## 1. Tổng quan & Mục tiêu
Nút bấm Reset (GPIO Push Button) phục vụ 2 chức năng chính trong quá trình vận hành thiết bị:
1. **Kích hoạt nhanh chế độ BLE Provisioning trong lúc vận hành (Runtime Provisioning):** Dành cho trường hợp người dùng muốn thay đổi/cấu hình lại Wi-Fi mà **không làm gián đoạn** hoạt động điều khiển Tải, đọc Cảm biến hay kết nối Mạng hiện tại.
2. **Khôi phục cài đặt gốc (Factory Reset):** Xóa sạch toàn bộ cấu hình lưu trữ trong Flash NVS (bao gồm Wi-Fi credentials, User ID, Cấu hình Cảm biến Modbus/Analog, Tên Tải, Safety Timeout...) và khởi động lại thiết bị về trạng thái ban đầu.

---

## 2. Quy tắc Thời gian & Hành vi Nhấn giữ (Hold Timing Rules)

| Thao tác | Phản hồi trực quan (Status LED) | Hành vi / Xử lý hệ thống | Trạng thái chuyển đổi (State Transition) |
| :--- | :--- | :--- | :--- |
| **Nhấn giữ $< 5$ giây** (không phải nhấn đôi) | Không thay đổi (giữ trạng thái LED hiện tại). | **Bỏ qua / Lọc nhiễu (Debounce 50ms)**. | Giữ nguyên trạng thái hiện tại. |
| **Nhấn nhanh 2 lần** (mỗi lần $< 0{,}8$ s, cách nhau $\le 0{,}5$ s) | Không đổi. | Bật/tắt chế độ in log (`PRINT_LOG`, xem mục 3.3). | Không đổi. |
| **Giữ $T \ge 5$ giây, nhả, không nhấn lại trong 2 giây** | **Chỉ LED_WIFI và LED_ETH nháy 2 Hz** từ mốc 5 giây và tiếp tục trong phiên provisioning. LED_ERROR giữ trạng thái báo lỗi hiện tại. Hết phiên, LED mạng phản ánh trạng thái thực tế. | Chỉ bật BLE Provisioning Runtime; không xóa dữ liệu. | **`STATE_BLE_PROV_RUNTIME`** |
| **Giữ $T \ge 5$ giây, nhả, rồi nhấn giữ lại $\ge 5$ giây trong vòng 2 giây** *(thực thi ngay tại mốc 5 giây của lần hai)* | Sau khi xóa NVS, LED_ERROR, LED_WIFI và LED_ETH cùng sáng 1 giây, tắt 1 giây, rồi sáng 1 giây; sau reboot, LED_WIFI và LED_ETH nháy 2 Hz trong provisioning. | Ngắt toàn bộ Tải (Relays $\to$ LOW/OFF), xóa toàn bộ NVS Flash, khởi động lại MCU (`esp_restart()`). | **`STATE_FACTORY_RESET`** $\to$ Reboot $\to$ **`STATE_BLE_PROV`** |

Nếu lần nhấn thứ hai trong cửa sổ 2 giây được nhả trước 5 giây thì chỉ thực hiện BLE Provisioning Runtime.

---

## 3. Chi tiết Luồng Xử lý & Yêu cầu Kỹ thuật (Detailed Functional Requirements)

### 3.1. Chế độ 1: BLE Provisioning Runtime (giữ $\ge 5$ giây, nhả, không nhấn lại)
- **Kích hoạt:** Người dùng giữ nút $\ge 5$ giây, nhả ra và không bắt đầu lần nhấn thứ hai trong 2 giây.
- **Phản hồi trực quan:** Chỉ LED_WIFI và LED_ETH nháy **2 Hz** từ $T = 5$ giây; LED_ERROR giữ trạng thái hiện tại. LED_WIFI và LED_ETH tiếp tục nhấp nháy trong provisioning; khi provisioning kết thúc, LED mạng quay về biểu thị giao diện đang hoạt động.
- **Hành vi hệ thống:**
  1. Khởi chạy BLE Protocomm Service (Prefix Service Name: `PROV_ESP32_`).
  2. **Cập nhật Wi-Fi an toàn:** Cho phép App di động quét và gửi Wi-Fi credentials mới qua endpoint `prov-config`.
  3. **Giữ vận hành an toàn khi đổi cấu hình:**
     - Nếu Wi-Fi đang là đường mạng hoạt động, thiết bị ngắt Wi-Fi tạm thời để thử thông tin mới; MQTT có thể ngắt và tự kết nối lại. Ethernet (nếu đang kết nối) không bị thay đổi.
     - Tác vụ đọc Modbus RS485 và điều khiển Tải tiếp tục vận hành; trạng thái các Rơ-le (Relays) giữ nguyên.
  4. **Thời hạn (Timeout):** Advertise tối đa **300 giây (5 phút)** mỗi phiên. Khi hết thời gian, dừng advertise; một cấu hình đã được nhận trước thời hạn được xử lý xong trước khi đóng dịch vụ BLE. Thiết bị đang vận hành quay về trạng thái vận hành; thiết bị chưa có cấu hình chờ giữ nút rồi nhả để mở một phiên 5 phút mới, không tự reboot để advertise lại.

---

### 3.2. Chế độ 2: Full Factory Reset NVM (giữ $\ge 5$ giây, nhả, rồi giữ lại 5 giây trong vòng 2 giây)
- **Kích hoạt:** Sau lần giữ $\ge 5$ giây, người dùng nhả nút, nhấn lại trong vòng 2 giây và giữ đủ **5 giây** (thực thi ngay lập tức tại mốc này, **không cần chờ nhả nút**).
- **Phản hồi trực quan:** Sau khi xóa NVS, LED_ERROR, LED_WIFI và LED_ETH cùng sáng 1 giây, tắt 1 giây, rồi sáng 1 giây; sau reboot vào provisioning, LED_WIFI và LED_ETH nhấp nháy **2 Hz**.
- **Hành vi hệ thống:**
  1. **An toàn thiết bị:** Ép toàn bộ 4 ngõ ra Điều khiển Tải (Relays/SSRs) về mức **LOW (TẮT)**.
  2. **Xóa toàn bộ dữ liệu NVM (NVS Flash Erase):** Gọi `nvs_flash_erase()` xóa sạch dữ liệu trong namespace `app_cfg` và `net_cfg`, bao gồm:
     - **Cấu hình Mạng & Định danh:** `wifi_ssid`, `wifi_password`, `user_id`, `only_use_ethernet`.
     - **Cấu hình Cảm biến Modbus RS485 & Analog:** Mọi cấu hình cài đặt `slave_id`, `name`, `enabled`, `baudrate` của 4 cổng RS485 và 1 cổng Analog 4-20 mA.
     - **Cấu hình Tải & An toàn:** Tên các ngõ ra Tải (`load_name`), `safety_timeout_s`.
     - **Dữ liệu chẩn đoán:** NVS Reset counters, error logs.
  3. **Tái khởi động:** Gọi `esp_restart()` sau 500 ms.
  4. **Trạng thái sau Reboot:** Thiết bị khởi động lại ở trạng thái **`STATE_INIT`**, phát hiện NVS rỗng và tự động nhảy vào **`STATE_BLE_PROV`** (Chờ Provisioning ban đầu).

---

### 3.3. Chế độ 3: Bật/tắt in log (nhấn nhanh 2 lần)
- **Kích hoạt:** Hai lần nhấn, mỗi lần $< 0{,}8$ giây, lần nhấn thứ hai bắt đầu trong vòng $0{,}5$ giây sau khi nhả lần đầu.
- **Hành vi:** Đảo trạng thái cờ in log (`app_log_toggle()`); trạng thái không được lưu qua reboot, mặc định tắt (`CONFIG_APP_LOG_DEFAULT_ENABLED`). Dòng xác nhận "application log ON/OFF" luôn được in.
- **Phạm vi:** Mọi thao tác quan trọng (init, deinit, start/stop, reconnect, failover, provisioning, ...) in qua `PRINT_LOG` (`components/app_log/include/app_log.h`) và chỉ in khi cờ bật. `ESP_LOGE` luôn in.

---

## 4. Đặc tả Kiến trúc Phần cứng & Phần mềm (Architecture & Implementation)

### 4.1. Khởi tạo Phần cứng (Hardware Interface)
- **GPIO Pin:** Đọc từ file cấu hình `main/app_pins.h` (ví dụ: `APP_PIN_BUTTON_RESET`).
- **Chế độ GPIO:** `GPIO_MODE_INPUT` với điện trở kéo lên nội (Pull-up) hoặc kéo ngoài (kiểm tra cả schematic).
- **Active Level:** `LOW` (Nút nhấn nối xuống GND khi bấm) (kiểm tra cả schematic).

### 4.2. Logic Task & Xử lý phần mềm (`app_sysmon` / `app_nvm`)
- Tác vụ **`sysmon_task`** (Core 1, Priority 2) quét trạng thái chân nút bấm định kỳ **10 ms - 50 ms**:
  - Sử dụng cơ chế Debounce 50 ms để loại bỏ nhiễu cơ học.
  - Khi phát hiện cạnh xuống (Button Pressed): Bắt đầu đếm thời gian bằng `esp_timer_get_time()`.
  - Giám sát thời gian thực (máy trạng thái trong `sysmon_task`):
    - Tại mốc **5 giây** của lần nhấn đầu: LED_WIFI và LED_ETH nháy 2 Hz; LED_ERROR giữ nguyên trạng thái.
    - Sau khi nhả: cửa sổ 2 giây. Hết cửa sổ mà không nhấn lại $\to$ `NET_CMD_START_BLE_PROV_RUNTIME`.
    - Lần nhấn thứ hai trong cửa sổ, tại mốc **5 giây**: `NET_CMD_FACTORY_RESET` và xóa NVS ngay; sau đó ba LED sáng 1 giây, tắt 1 giây, sáng 1 giây trước reboot. Nhả trước 5 giây $\to$ chỉ provisioning.
    - Hai lần nhấn nhanh $\to$ `app_log_toggle()`.
  - Khi phát hiện cạnh lên (Button Released) (kiểm tra schematic): chuyển trạng thái theo các luật trên; nhấn $< 5$ giây không phải nhấn đôi thì bỏ qua.

---

## 5. Tiêu chuẩn Kiểm thử & Nghiệm thu (Acceptance Criteria - AC)

| Test ID | Tên kịch bản | Thao tác thực hiện | Kết quả kỳ vọng (Pass Criteria) |
| :--- | :--- | :--- | :--- |
| **AC-BTN-01** | Press Debounce & Ignore | Nhấn giữ nút trong 3 giây rồi nhả. | Thiết bị không thay đổi trạng thái, LED_ERROR không nháy, không bị ngắt mạng/MQTT. |
| **AC-BTN-02** | Runtime Provisioning Trigger | Nhấn giữ nút 6 giây rồi nhả, không nhấn lại. | Từ mốc 5s: chỉ LED_WIFI và LED_ETH nháy 2 Hz; LED_ERROR giữ nguyên. Sau 2 s kể từ lúc nhả: chuyển sang `STATE_BLE_PROV_RUNTIME`, BLE bật quảng cáo, các Tải vẫn hoạt động bình thường, không bị xóa NVS. |
| **AC-BTN-03** | Full Factory Reset Execution | Giữ 6 giây, nhả, nhấn lại trong 2 giây và giữ liên tục 5 giây. | Đúng mốc 5s của lần hai: ngắt toàn bộ Tải (Relays LOW), xóa sạch NVS Flash; LED_ERROR, LED_WIFI và LED_ETH cùng sáng 1 giây, tắt 1 giây, sáng 1 giây rồi reboot MCU. Sau reboot, thiết bị vào `STATE_BLE_PROV` và LED_WIFI/LED_ETH nháy theo provisioning. |
| **AC-BTN-04** | NVS Config Clearance Verify | Đổi tên Cảm biến & Tải qua App, sau đó thực hiện Reset (giữ 6 s, nhả, giữ lại 5 s). | Sau khi reboot và provision lại, toàn bộ tên Cảm biến, Tải, SSID Wi-Fi cũ bị xóa hoàn toàn, khôi phục về giá trị Mặc định (Default Config). |
| **AC-BTN-05** | Second press too short | Giữ 6 giây, nhả, nhấn lại 2 giây rồi nhả. | Không reset; thực hiện Runtime Provisioning. |
| **AC-BTN-06** | Log toggle | Nhấn nhanh 2 lần. | Log ứng dụng đổi giữa tắt và bật; lần nhấn đôi tiếp theo đảo lại. Thao tác init/reconnect chỉ in khi log bật. |