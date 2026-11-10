# Technical Requirements & Implementation Specification: ESP32-S3 Network Failover & MQTT Resilience Engine

**Project:** Aquaculture Pond / Industrial Monitoring Controller
**Target MCU:** ESP32-S3-WROOM-1U (Dual-Core Xtensa LX7, 240 MHz, 8 MB PSRAM / 16 MB Flash)
**Framework:** ESP-IDF v5.x (FreeRTOS, LwIP, ESP-MQTT, NimBLE Protocomm)
**Document Version:** 3.0 (Final, consolidated)

Các giá trị đánh dấu **[Default]** là giá trị mặc định, phải cấu hình được qua Kconfig / `app_config_t`. Bảng tổng hợp ở Phần 11.

---

## 1. Tổng quan & Mục tiêu

Module `app_network` kết hợp `app_mqtt` duy trì kết nối mạng liên tục 24/7 cho thiết bị ESP32-S3-WROOM-1U, với dự phòng giữa **Ethernet SPI (W5500)** và **Wi-Fi Station (802.11 b/g/n)**.

Mục tiêu:

* Thông điệp MQTT Telemetry/Command luôn được truyền nhận an toàn khi hạ tầng mạng chập chờn hoặc mất WAN.
* Failover/failback tự động, không reboot, không rò rỉ RAM, không gây Reconnect Storm.
* Không mất dữ liệu telemetry khi mất mạng ngắn hạn (buffer RAM 50 bản tin).
* Đưa tải về trạng thái an toàn khi mất cả hai đường mạng quá 300 giây.

> Đây là **failover nhanh kèm reconnect MQTT**, không phải "seamless": TCP session không được giữ nguyên khi đổi interface.

### 1.1 Chiến lược triển khai Incremental / Bottom-Up (bắt buộc cho AI Codegen)

Triển khai theo 4 module độc lập; mỗi module phải build và đạt AC liên quan trước khi sang module kế tiếp:

1. **Module 1: Wi-Fi Station Engine:** khởi tạo Wi-Fi STA, reconnect backoff, xử lý sự cố L2/L3.
2. **Module 2: W5500 SPI Ethernet Driver:** SPI Host, driver W5500, health check `VERSIONR`, hard reset.
3. **Module 3: Netif Manager & Isolated Probe FSM:** chọn route, ICMP probe cô lập, chuyển Active Interface kèm tear-down socket và cập nhật DNS.
4. **Module 4: Resilient MQTT Client & Telemetry Buffer:** `esp-mqtt` với `disable_auto_reconnect`, backoff full jitter, buffer tĩnh thread-safe.

---

## 2. System Architecture

### 2.1 Task Map & Core Pinning

Toàn bộ logic Mạng, Socket, LwIP, Probe và MQTT Client chạy trên **Core 0**, cách ly với đọc cảm biến Modbus RS485 và điều khiển tải ở **Core 1**.

| Task | Core | Priority | Stack | Ghi chú |
| :--- | :--- | :--- | :--- | :--- |
| `net_mgmt_task` | 0 | 6 | 8192 | FSM mạng, probe engine, W5500 health check, chủ sở hữu duy nhất của default netif. |
| `mqtt_client_task` | 0 | 5 | 6144 | Task **nội bộ** của `esp-mqtt` (cấu hình qua `esp_mqtt_client_config_t.task.priority/stack_size`; ghim Core 0 bằng `CONFIG_MQTT_TASK_CORE_SELECTION_ENABLED`). |
| `app_ble_prov` | 0 | 4 | theo NimBLE | Chỉ tồn tại trong `STATE_BLE_PROV` / `STATE_BLE_PROV_RUNTIME`; giải phóng hoàn toàn khi thoát. |
| `esp_timer`, `sys_evt` | 0 | system | dynamic | Mặc định ESP-IDF, xử lý Wi-Fi/ETH system events. |
| `sensor_modbus_task` | 1 | 5 | 4096 | Đọc Modbus RS485, đẩy dữ liệu vào Telemetry Buffer. |
| `load_control_task` | 1 | 7 | 3072 | Điều khiển 4 relay, nhận lệnh Safety Interlock. |
| `sysmon_task` | 1 | 2 | 3072 | Nút nhấn, LED, giám sát heap và stack high-water mark. |

Quy tắc:

* Giá trị stack là mức khởi điểm. Bắt buộc đo `uxTaskGetStackHighWaterMark()` và giữ dư **> 1024 bytes** mỗi task.
* `net_mgmt_task` và các task quan trọng đăng ký **Task Watchdog** (xem 3.9).
* Mọi thao tác thay đổi trạng thái mạng/MQTT chỉ thực hiện trong `net_mgmt_task`. Task/callback khác (MQTT event handler, nút nhấn, timer) **chỉ gửi message** vào `net_cmd_queue`.

### 2.2 Event Group & Shared State

```c
EventGroupHandle_t xNetEventGroup;

#define BIT_NET_ETH_LINK_UP     (1 << 0)  // L2: cáp cắm
#define BIT_NET_ETH_GOT_IP      (1 << 1)  // L3: ETH có IP
#define BIT_NET_ETH_WAN_OK      (1 << 2)  // WAN verdict của ETH = OK
#define BIT_NET_WIFI_GOT_IP     (1 << 3)  // Wi-Fi STA có IP
#define BIT_NET_WIFI_WAN_OK     (1 << 4)  // WAN verdict của Wi-Fi = OK
#define BIT_NET_ACTIVE_READY    (1 << 5)  // Active Interface có IP và WAN OK
#define BIT_MQTT_CONNECTED      (1 << 6)  // MQTT đang CONNECTED với Broker
#define BIT_NET_STANDBY_READY   (1 << 7)  // Interface còn lại có IP và WAN OK (cache)
#define BIT_TIME_VALID          (1 << 8)  // SNTP đã sync
#define BIT_SYS_NET_LOST        (1 << 9)  // Mất cả hai đường mạng
#define BIT_PROV_ACTIVE         (1 << 10) // Đang trong BLE provisioning
```

Khi một interface có `LINK_DOWN` / mất IP / `WAN FAIL`, xóa các bit `*_GOT_IP` / `*_WAN_OK` tương ứng và tính lại `ACTIVE_READY`, `STANDBY_READY` trong cùng một hàm `net_recompute_bits()`.

Trạng thái phức (enum, struct) lưu trong `net_state_t`, bảo vệ bằng **Mutex**, truy cập qua getter/setter:

```c
typedef enum { NET_IF_NONE, NET_IF_ETH, NET_IF_WIFI } net_if_t;

typedef struct {
    net_if_t    active_if;            // interface đang là default netif
    net_if_t    standby_if;
    uint8_t     mqtt_retry_count;
    uint8_t     wifi_retry_count;
    bool        wifi_unverified_wan;
    app_state_t fsm_state;
} net_state_t;
```

Cấm dùng biến `bool`/enum global trần để chia sẻ giữa Core 0 và Core 1.

### 2.3 Init-Once Rules (chống Memory Leak, CỰC KỲ QUAN TRỌNG)

* `esp_netif_create_default_wifi_sta()`, tạo ETH netif, `esp_event_handler_register()`, `esp_mqtt_client_init()` chỉ gọi **đúng 1 lần** lúc khởi động. Cấm gọi trong vòng lặp reconnect/failover.
* Khi mất mạng chỉ dùng `esp_wifi_connect()`, `esp_mqtt_client_stop()` / `esp_mqtt_client_start()`.
* Mọi `esp_ping_new_session()` phải có `esp_ping_delete_session()` tương ứng (3.2).

---

## 3. Network Policy & Technical Rules

### 3.1 Interface Roles & Route Selection

* **Primary:** Ethernet SPI W5500. **Standby:** Wi-Fi Station (giữ kết nối AP khi có credentials để sẵn sàng failover).
* **Netif priority:** khi tạo netif phải cấu hình `route_prio` của ETH **cao hơn** Wi-Fi STA (mặc định ESP-IDF thường ngược lại; kiểm tra với đúng phiên bản IDF đang dùng).
* **Không chỉ dựa vào priority:** ETH còn IP nhưng mất WAN vẫn thắng về priority. `net_mgmt_task` là chủ sở hữu duy nhất của default netif và gọi `esp_netif_set_default_netif()` tường minh theo kết quả probe.
* esp_netif có thể tự đặt lại default netif khi có `GOT_IP`; sau **mọi** `IP_EVENT_*` phải gọi `net_select_active()` để khẳng định lại Active Interface theo FSM.
* Khi hai interface cùng subnet, probe của mỗi interface phải được ghim bằng `interface` (3.2).

### 3.2 WAN Probe Engine (Isolated Validation)

Event L2/L3 không chứng minh có Internet, nên dùng probe chủ động để quyết định `*_WAN_OK`.

**Probe cô lập:**

* Dùng `esp_ping`, ghim vào đúng interface qua `esp_ping_config_t.interface = esp_netif_get_netif_impl_index(netif)`. Không được ảnh hưởng default netif đang chạy.
* Cấu hình: `count = 3`, `timeout_ms = 1000`, `interval_ms = 1000`. **Thành công** nếu nhận ≥ 1/3 reply; **thất bại** nếu 3/3 timeout.
* Mỗi lần probe tạo 1 session; callback `on_ping_end` báo kết quả cho `net_mgmt_task`; `esp_ping_delete_session()` luôn được gọi sau khi kết thúc, kể cả trên nhánh lỗi.

**Đích probe [Default]:** `1.1.1.1` và `8.8.8.8` (cấu hình được; hiện probe song song trên từng interface). **Không dùng ping Gateway để kết luận WAN**; ping Gateway chỉ để ghi log chẩn đoán L3. Bất kỳ phản hồi ICMP nào từ một trong hai đích là **WAN OK**; không có phản hồi từ cả hai là **WAN FAIL**.

**Phạm vi đã chốt:** TCP probe tới MQTT broker không bắt buộc và không được dùng làm WAN fallback. Mất kết nối tới broker không chứng minh WAN hỏng; broker-only outage phải giữ nguyên interface và để MQTT reconnect/backoff xử lý. ICMP là phép thử WAN hiện tại. Trước nghiệm thu, xác nhận mạng triển khai cho phép ICMP tới ít nhất một probe target; nếu không, phải chốt và kiểm thử một phương thức WAN độc lập với broker trước khi nghiệm thu. Không coi ICMP-only là verdict đã xác thực trên mạng chặn ICMP.

**Tần suất [Default]:**

| Ngữ cảnh | Chu kỳ |
| :--- | :--- |
| Active Interface, ổn định | 1 giây |
| Standby Interface, ổn định | 1 giây (cập nhật `BIT_NET_STANDBY_READY`) |
| Đang khôi phục (`STATE_NET_LOST`, hoặc probe vừa fail) | 1 giây |
| Failback check Ethernet (3.4) | 1 giây |

### 3.3 Failover Triggers & Procedure

**Triggers (một trong):**

1. **Tức thời:** Active Interface nhận `ETHERNET_EVENT_DISCONNECTED` / `WIFI_EVENT_STA_DISCONNECTED` / `IP_EVENT_*_LOST_IP` (kể cả mất DHCP lease). **Không chờ ping.**
2. **Probe:** WAN verdict của Active Interface = FAIL.

**Điều kiện chuyển:** chỉ chuyển khi `BIT_NET_STANDBY_READY` còn hiệu lực. Nếu cache cũ hoặc chưa sẵn sàng, chạy 1 probe xác minh standby (tối đa ~3 giây). Standby không sẵn sàng thì vào `STATE_NET_LOST`.

**Thủ tục chuyển Interface** (thực hiện trong `net_mgmt_task`, đúng thứ tự):

```c
// 1) Đóng socket MQTT cũ
esp_mqtt_client_stop(client);
// 2) Đổi default netif
esp_netif_set_default_netif(new_netif);
// 3) Cập nhật DNS global của LwIP theo netif mới
esp_netif_dns_info_t dns;
esp_netif_get_dns_info(new_netif, ESP_NETIF_DNS_MAIN, &dns);
ip_addr_t d; /* convert dns.ip -> d */
dns_setserver(0, &d);
// 4) Tạo socket mới trên IP mới
esp_mqtt_client_start(client);
```

* Cấm gọi `esp_mqtt_client_stop()`/`start()` bên trong MQTT event handler (nguy cơ deadlock); handler chỉ gửi message vào `net_cmd_queue`.
* Telemetry tiếp tục ghi vào Buffer trong suốt quá trình (Phần 6).

### 3.4 Failback Hysteresis (chống Flapping)

* Khi Ethernet trở lại (link up + got IP) trong lúc đang chạy Wi-Fi: **không** chuyển ngay.
* Chạy probe ETH mỗi **1 giây**; cần **5 lần OK liên tiếp (≈ 5 giây ổn định)** mới failback. Bất kỳ lần fail hoặc link-down nào reset bộ đếm về 0.
* Failback dùng cùng thủ tục chuyển ở 3.3. Wi-Fi giữ nguyên kết nối làm standby.

### 3.5 Fault Isolation (Broker Down vs WAN Down)

| Tình huống | Quan sát | Xử lý |
| :--- | :--- | :--- |
| **Broker Down** | WAN verdict OK, MQTT connect fail | Giữ nguyên Interface, backoff reconnect MQTT tại chỗ. **Không** vào `STATE_FAILOVER`. |
| **WAN Down** | WAN verdict FAIL | Vào `STATE_FAILOVER`. |
| **Mất cả hai** | Cả hai interface không sẵn sàng | Vào `STATE_NET_LOST`. |

### 3.6 Anti-Reconnect Storm: Exponential Backoff with Full Jitter

$$T_{backoff} = \text{random}(0, \min(T_{max}, T_{base} \times 2^{attempt}))$$

* $T_{base} = 1\,\text{s}$, $T_{max} = 60\,\text{s}$, `attempt = min(attempt, 10)` (chống tràn số). **[Default]** sàn `200 ms` để tránh retry tức thời khi jitter ra giá trị gần 0.
* Áp dụng cho **MQTT** (`mqtt_retry_count`) và **Wi-Fi AP reconnect** (`wifi_retry_count`), hai bộ đếm riêng.
* Bắt buộc `esp_mqtt_client_config_t.network.disable_auto_reconnect = true`. Reconnect do `net_mgmt_task` điều khiển bằng `esp_timer` one-shot gửi message về queue.
* **Reset `retry_count = 0`** ngay khi `MQTT_EVENT_CONNECTED` (và `IP_EVENT_STA_GOT_IP` đối với Wi-Fi).

```c
static uint32_t backoff_ms(uint8_t attempt) {
    if (attempt > 10) attempt = 10;
    uint32_t cap = MIN(60000u, 1000u << attempt);
    uint32_t v = esp_random() % (cap + 1);
    return MAX(200u, v);
}
```

### 3.7 Safety Interlock (300 giây)

* `BIT_SYS_NET_LOST` được set khi vào `STATE_NET_LOST`; đồng hồ 300 giây bắt đầu đếm từ lúc đó và **reset** khi có bất kỳ interface nào đạt WAN OK.
* Đủ 300 giây: `net_mgmt_task` gửi event cho `load_control_task` (Core 1) ngắt cả **4 Relay** (`GPIO LOW`).
* Khi mạng phục hồi, relay **không** tự bật lại; giữ TẮT cho đến khi nhận lệnh `SET_STATE` mới từ MQTT.
* **Trạng thái relay khi boot [Default]: TẮT** cho tới khi có lệnh `SET_STATE`.
* Trong khoảng < 300 giây mất mạng, relay giữ nguyên trạng thái hiện tại.

### 3.8 W5500 Hardware Hardening

* Định kỳ (mỗi 1 giây) đọc thanh ghi `VERSIONR` (địa chỉ `0x0039`, giá trị chuẩn `0x04`). Đọc ra `0x00` hoặc `0xFF` quá **3 lần liên tiếp** thì xác định SPI treo.
* **Reset sequence:** `esp_eth_stop()` → kéo `ETH_RST_PIN` LOW 50 ms → HIGH → gỡ driver (`esp_eth_driver_uninstall()`) → khởi tạo lại SPI Master → `esp_eth_driver_install()` → `esp_eth_start()`.
* Giới hạn **tối đa 3 lần/giờ**; vượt giới hạn thì đánh dấu ETH `FAULT`, hệ thống chạy Wi-Fi-only và ghi log cho tới khi reboot.
* Trong lúc reset, ETH coi như link-down (kích hoạt failover tức thời nếu đang active).

### 3.9 Watchdog & Recovery

* `net_mgmt_task` đăng ký Task WDT; không feed trong timeout **[Default] 30 giây** thì reboot (relay mặc định TẮT khi boot, theo 3.7).
* Ghi `reset_reason`, số lần failover và số lần reset W5500 vào NVS để chẩn đoán.

---

## 4. Finite State Machine

```text
                       +------------------+
                       |    STATE_INIT    |
                       +--------+---------+
                                |
             +------------------+------------------+
             | NVS empty AND no cable              | config valid OR cable
             v                                     v
   +--------------------+                +----------------------+
   |   STATE_BLE_PROV   |  provision OK  | STATE_NET_CONNECTING |
   |    (first-time)    +--------------->|                      |
   +--------------------+                +----------+-----------+
                                                    | IP + WAN OK
                                                    v
                                        +-----------------------+
                                        | STATE_MQTT_CONNECTING |
                                        +-----------+-----------+
                                                    | MQTT connected
                                                    v
        +-------------------------+     +-----------------------+
        | STATE_BLE_PROV_RUNTIME  |<----+   STATE_OPERATIONAL   |
        | (button 5s, MQTT keeps  |---->+-----------+-----------+
        |  running)               | done/           | WAN fail / link down
        +-------------------------+ timeout         v
                                        +-----------------------+
                                        |    STATE_FAILOVER     |
                                        +-----+-----------+-----+
                                              |           |
                                standby ready |           | no standby
                                              v           v
                                   STATE_MQTT_CONNECTING  +----------------+
                                                          | STATE_NET_LOST |
                                                          +-------+--------+
                                                                  |
                                   any WAN OK -> STATE_MQTT_CONNECTING
                                   300 s      -> Safety Interlock (relays OFF)

   Any state, button: hold >= 5 s, release, hold again 5 s within 2 s -> STATE_FACTORY_RESET -> reboot
   STATE_NET_CONNECTING, timeout 30 s -> STATE_NET_LOST
   STATE_MQTT_CONNECTING, WAN fail -> STATE_FAILOVER
```

### 4.1 State Table

| State | Hành động | Chuyển tiếp |
| :--- | :--- | :--- |
| **`STATE_INIT`** | Khởi tạo GPIO, SPI, NVS, UART, event loop, netif (init-once). Đọc `app_config_t` từ NVS. Relay = OFF. | NVS rỗng **và** không cắm cáp → `BLE_PROV`. Có config hoặc có cáp → `NET_CONNECTING`. |
| **`STATE_BLE_PROV`** (first-time) | Bật NimBLE advertising, mở endpoint `prov-config`. **Ngắt toàn bộ tải.** Nhận Wi-Fi config → Isolated Probe (Phần 5) → lưu NVS. | Provision xong → `NET_CONNECTING`. |
| **`STATE_NET_CONNECTING`** | Bật các interface khả dụng, chờ DHCP IP, chạy WAN probe. Chọn interface đầu tiên đạt IP + WAN OK (ưu tiên ETH). | IP + WAN OK → `MQTT_CONNECTING`. Timeout **[Default] 30 s** không interface nào sẵn sàng → `NET_LOST`. |
| **`STATE_MQTT_CONNECTING`** | Cập nhật DNS (3.3), `esp_mqtt_client_start()`. Thất bại → backoff reconnect tại chỗ (3.6). | `MQTT_EVENT_CONNECTED` → `OPERATIONAL`. WAN FAIL → `FAILOVER`. Broker fail mà WAN OK → ở lại (3.5). |
| **`STATE_OPERATIONAL`** | Telemetry/command qua MQTT. Probe Active mỗi 5 s, Standby mỗi 20 s. Flush buffer (Phần 6). Failback check khi ETH trở lại (3.4). BLE stack **tắt** (giải phóng ~40 KB heap). | Trigger failover (3.3) → `FAILOVER`. Giữ nút 5 s → `BLE_PROV_RUNTIME`. |
| **`STATE_FAILOVER`** | Thủ tục chuyển Interface (3.3). LED_ERROR 1 Hz. | Standby sẵn sàng → `MQTT_CONNECTING`. Không có → `NET_LOST`. |
| **`STATE_NET_LOST`** | Set `BIT_SYS_NET_LOST`, đếm 300 s (3.7). Probe cả hai interface mỗi 2 s. LED_ERROR 1 Hz. MQTT stopped. Wi-Fi reconnect theo backoff. | Có interface WAN OK → clear timer → `MQTT_CONNECTING`. Đủ 300 s → Safety Interlock (vẫn ở `NET_LOST` tới khi có mạng). |
| **`STATE_BLE_PROV_RUNTIME`** | Bật BLE khi đang chạy. **Giữ nguyên MQTT, mạng và trạng thái tải.** Timeout **[Default] 180 s**. Nhận Wi-Fi config → Isolated Probe → lưu NVS (Phần 5). | Hoàn tất/timeout/hủy → tắt BLE, quay lại `OPERATIONAL`. |
| **`STATE_FACTORY_RESET`** | Từ **mọi state** khi giữ nút ≥ 5 s, nhả, rồi giữ lại 5 s trong vòng 2 s. Tải OFF, LED_ERROR 10 Hz, `nvs_flash_erase()`, reboot. | Reboot → `INIT`. |

### 4.2 Button Handling (`sysmon_task`, Core 1)

* Debounce 50 ms. `sysmon_task` đo thời gian giữ và gửi event vào `net_cmd_queue`.
* **Giữ ≥ 5 s, nhả nút:** LED nhấp nháy 2 Hz từ mốc 5 s. Mở cửa sổ **2 s** sau khi nhả:
  * Không có lần nhấn thứ hai (hoặc lần hai nhả trước 5 s) → chỉ yêu cầu `BLE_PROV_RUNTIME` (provisioning, không xóa dữ liệu).
  * Nhấn lần hai trong cửa sổ và giữ đủ **5 s** → `FACTORY_RESET`, thực thi ngay tại mốc 5 s; sau khi xóa NVS, LED_ERROR, LED_WIFI và LED_ETH cùng sáng 1 s, tắt 1 s, sáng 1 s rồi khởi động lại vào provisioning.
* **Nhấn 2 lần nhanh** (mỗi lần < 0,8 s, cách nhau ≤ 0,5 s): bật/tắt chế độ in log (`PRINT_LOG`).
* Các thao tác nhấn khác (ví dụ giữ 0,8–5 s): bỏ qua.

---

## 5. BLE Provisioning & Isolated Wi-Fi Verification

### 5.1 Hai chế độ

| Chế độ | Khi nào | Tải | MQTT |
| :--- | :--- | :--- | :--- |
| First-time (`BLE_PROV`) | NVS rỗng và không cắm cáp | OFF | Chưa có |
| Runtime (`BLE_PROV_RUNTIME`) | Giữ nút 5 s khi đang OPERATIONAL | Giữ nguyên | Giữ nguyên |

BLE chỉ dùng cho provisioning: tắt và giải phóng RAM ngay khi hoàn tất, timeout hoặc hủy.

### 5.2 Quy tắc provisioning khi đang chạy

* Runtime provisioning cho phép đổi Wi-Fi kể cả khi Wi-Fi đang là Active Interface. Firmware ngắt STA hiện tại trước khi thử thông tin mới; MQTT có thể mất kết nối tạm thời và tự kết nối lại. Nếu kết nối mới thất bại, firmware khôi phục thông tin Wi-Fi đã lưu. Chỉ trả `ERR_WIFI_ACTIVE_BUSY` nếu STA hiện tại không ngắt được trong thời hạn chờ.
* Credentials mới chỉ ghi đè credentials cũ trong NVS **sau khi** L2/L3 thành công. Sai mật khẩu hoặc không kết nối được AP: giữ nguyên credentials cũ, trả `ERR_WIFI_CONNECT_FAILED`.
* Bảo mật: dùng protocomm security (khuyến nghị security 1/2) với proof-of-possession.

### 5.3 Quy trình

1. **Kết nối L2/L3:** ESP32 kết nối Wi-Fi AP và nhận IP nội bộ.
2. **Isolated Probe (mục 3.2, `count = 3`)** ghim vào `netif_wifi`. Default netif **không đổi**; MQTT vẫn chạy trên Ethernet (nếu đang active).
3. **Phân nhánh kết quả:**
   * **WAN OK:** lưu NVS, `unverified_wan = false`, Wi-Fi sẵn sàng làm Standby. Trả BLE `{"status": "SUCCESS"}`.
   * **WAN FAIL (3/3):** vẫn lưu NVS với `unverified_wan = true`, **không** chuyển route, giữ MQTT 100% trên Ethernet. Trả BLE cảnh báo:

```json
{
  "status": "WARNING",
  "error_code": "WARN_WIFI_NO_INTERNET",
  "retry_attempts": 3,
  "active_interface": "ETH",
  "message": "Wi-Fi AP connected (L2/L3 OK), but WAN ping failed after 3 attempts."
}
```

### 5.4 Quy tắc phụ

* `error_code` là khóa chính để app xử lý; `message` chỉ để hiển thị, giữ ngắn (payload BLE ≤ MTU đã thương lượng, hoặc chunk theo protocomm).
* `unverified_wan` được kiểm tra lại theo chu kỳ probe Standby (20 s); khi probe OK thì xóa flag.
* Khi Active Interface mất mà Wi-Fi vẫn `unverified_wan = true`: vẫn chạy probe xác minh standby (3.3), chỉ chuyển nếu probe OK.
* Mã trạng thái: `SUCCESS`, `WARN_WIFI_NO_INTERNET`, `ERR_WIFI_CONNECT_FAILED`, `ERR_WIFI_ACTIVE_BUSY`, `ERR_PROV_TIMEOUT`.

### 5.5 NVS Keys (namespace `net_cfg`)

| Key | Kiểu | Mô tả |
| :--- | :--- | :--- |
| `wifi_ssid`, `wifi_pass` | string | Credentials Wi-Fi (khuyến nghị bật NVS encryption). |
| `unverified_wan` | u8 | 1 nếu Wi-Fi chưa xác minh được WAN. |
| `broker_uri` | string | `mqtt://` hoặc `mqtts://` host:port. |
| `reset_reason`, `failover_cnt`, `w5500_reset_cnt` | u32 | Chẩn đoán. |

---

## 6. Telemetry Buffering & Time Sync

### 6.1 Buffer

* Mảng tĩnh **50 slot**, mỗi slot struct cố định **256 bytes** (≈ 12.8 KB), bảo vệ bằng **FreeRTOS Mutex** (producer ở Core 1, consumer ở Core 0).
* Slot lưu **dữ liệu nhị phân/struct**; JSON được serialize lúc gửi (tránh vượt 256 byte).

```c
typedef struct {
    uint32_t seq;          // tăng đơn điệu, backend dùng để khử trùng
    int64_t  ts_unix_ms;   // 0 nếu time_valid = false
    uint32_t uptime_ms;    // luôn có
    uint8_t  payload[240]; // dữ liệu cảm biến (struct)
} telemetry_slot_t;
```

* Khi `BIT_MQTT_CONNECTED` bị xóa, `sensor_modbus_task` vẫn tiếp tục đẩy dữ liệu vào buffer.
* **Buffer đầy: xóa bản cũ nhất (FIFO drop-oldest)** để giữ dữ liệu mới nhất, tăng `drop_count`. Dùng ring tự viết (head/tail/count + mutex); không dùng `RingBuffer`/`Queue` của FreeRTOS cho việc ghi đè.

### 6.2 Quy tắc publish

* **Không publish khi `BIT_MQTT_CONNECTED` = 0** (tránh outbox của esp-mqtt phình heap với QoS > 0); giới hạn outbox trong cấu hình esp-mqtt.
* Khi `BIT_MQTT_CONNECTED` được set lại: gửi bản tin **Live trước**, rồi flush buffer theo thứ tự cũ → mới với khoảng cách **100 ms/bản tin** để không nghẽn socket. Ngừng flush ngay nếu MQTT rớt lại; bản tin chưa gửi giữ nguyên trong buffer.
* QoS1 có thể gây trùng lặp; backend dùng `seq` để khử trùng.

### 6.3 SNTP

* Đồng bộ SNTP sau khi có WAN; set `BIT_TIME_VALID`. Khi `time_valid = false`, ghi `ts_unix_ms = 0` và vẫn ghi `uptime_ms`.
* TLS (nếu bật) yêu cầu thời gian hợp lệ trước khi xác thực chứng chỉ.

---

## 7. Security

* MQTT khuyến nghị TLS (cổng 8883) với CA pinning; lưu chứng chỉ ở phân vùng riêng.
* Bật NVS encryption cho credentials Wi-Fi/broker.
* BLE provisioning dùng protocomm security với PoP; BLE chỉ mở có thời hạn (180 s) và chỉ khi người dùng giữ nút (hoặc lần đầu chưa có cấu hình).

---

## 8. Mối nguy & Anti-Pattern Rules (bắt buộc tuân thủ)

1. **Memory Leak khi Reconnect:** init-once cho netif, event handler, `esp_mqtt_client` (2.3).
2. **Ping session:** mọi `esp_ping_new_session` phải có `delete_session` (3.2).
3. **MQTT stop/start:** không gọi trong MQTT event handler (3.3).
4. **Thread-safety Dual-Core:** không dùng biến global trần giữa Core 0 và Core 1; dùng Event Group + Mutex (2.2).
5. **Ping Gateway** không dùng để kết luận WAN (3.2).
6. **Không publish** khi MQTT chưa connected (6.2).
7. **Không ghi đè credentials NVS** trước khi L2/L3 thành công (5.2).
8. **Lock-up W5500 SPI:** health check `VERSIONR` và hard reset theo 3.8.

---

## 9. Acceptance Criteria & Hardware Test Matrix

| ID | Hạng mục | Kịch bản | Điều kiện Đạt |
| :--- | :--- | :--- | :--- |
| **AC-01** | Ethernet Unplug Failover | Rút cáp ETH khi đang gửi telemetry, Wi-Fi standby đã sẵn sàng. | Từ lúc link-down đến `MQTT_EVENT_CONNECTED` trên Wi-Fi **< 5 s**; dữ liệu trong lúc gián đoạn nằm trong buffer. |
| **AC-02** | Silent WAN Failure | Rút cáp WAN ở Router (dây LAN ESP32 vẫn cắm). | Probe 3/3 fail, chuyển sang Wi-Fi trong **≤ 10 s** (chu kỳ 5 s + probe 3 s + chuyển). |
| **AC-03** | Failback Hysteresis | Cắm lại ETH khi đang chạy Wi-Fi. | Chỉ chuyển về ETH sau **5 probe OK liên tiếp (≈ 15 s)**; không reset chip. |
| **AC-04** | Flapping Cable | Cắm/rút ETH 5 lần, cách nhau 2 s. | Không reconnect MQTT liên tục; Wi-Fi giữ làm active tới khi ETH ổn định 15 s. |
| **AC-05** | Broker Down Only | Chặn port MQTT trên server (Internet vẫn OK). | **Không** đổi interface; các khoảng reconnect nằm trong `[0, min(60 s, 1 s·2^n)]` (có sàn 200 ms). |
| **AC-06** | Anti-Reconnect Storm | Tắt Broker và cả hai mạng trong 30 phút. | Số lần connect bị giới hạn theo backoff; CPU Core 0 không quá tải; free heap không giảm quá 2 KB. |
| **AC-07** | Runtime Provisioning (Wi-Fi no WAN) | ETH active, giữ nút 5 s, cấu hình Wi-Fi AP không có Internet qua BLE. | Probe **đúng 3 lần**, trả `WARN_WIFI_NO_INTERNET`, không đổi default netif, MQTT và tải không gián đoạn; BLE tắt khi xong/timeout, heap trả về trong ±2 KB. |
| **AC-08** | First-time Provisioning | Boot với NVS rỗng, không cắm cáp. | Vào `BLE_PROV`, tải OFF; provision thành công → `NET_CONNECTING` → `MQTT_CONNECTING` → `OPERATIONAL`. |
| **AC-09** | Button provisioning / reset / log | Giữ 3 s; giữ 6 s rồi nhả; giữ 6 s, nhả, giữ lại 5 s trong 2 s; nhấn 2 lần nhanh. | 3 s: bỏ qua. 6 s rồi nhả: sau 2 s vào provisioning. Giữ lại 5 s: factory reset thực thi tại mốc 5 s của lần hai. 2 lần nhanh: bật/tắt in log. |
| **AC-10** | Buffer & Flush | Ngắt mạng 60 s (30 mẫu), bật lại. Thêm ca ngắt dài làm tràn > 50 mẫu. | 30 mẫu được flush theo thứ tự, `seq` liên tục, không trùng, không nghẽn socket; ca tràn: giữ đúng 50 mẫu mới nhất, `drop_count` đúng. |
| **AC-11** | Safety Interlock | Rút cáp LAN và tắt Router Wi-Fi > 300 s. | Đúng 300 s ngắt 4 relay; mạng phục hồi vẫn TẮT cho tới khi có `SET_STATE`; boot lại cũng mặc định TẮT. |
| **AC-12** | W5500 SPI Recovery | Làm chập SCK/MOSI W5500 xuống GND. | Phát hiện `VERSIONR` sai sau 3 lần, reset RST pin, khôi phục driver; lần thứ 4 trong 1 giờ không reset nữa, hệ thống chạy Wi-Fi-only. |
| **AC-13** | Same Subnet | Cắm LAN và Wi-Fi cùng router (`192.168.1.x`). | Default netif = Ethernet; probe Wi-Fi bị ghim đúng interface; không routing loop. |
| **AC-14** | Ping Session / Memory Leak | Thực hiện failover/failback 100 lần. | Free heap sau 100 chu kỳ không giảm quá **2 KB**; largest free block không giảm đáng kể; mọi session ping đã được `delete`. |
| **AC-15** | Soak Test | 200 chu kỳ failover trong 24 giờ. | Không phân mảnh đáng kể; `uxTaskGetStackHighWaterMark` **> 1024 bytes** trên mọi task; Task WDT không kích hoạt. |
| **AC-16** | SNTP chưa sync | Boot khi chưa có Internet, có telemetry. | `ts_unix_ms = 0`, `uptime_ms` hợp lệ; sau khi sync các bản mới có timestamp đúng. |
| **AC-17** | Mất DHCP lease | Làm Active Interface mất lease/IP. | Coi như link-down, failover tức thời. |
| **AC-18** | Boot Matrix | Boot 4 tổ hợp: (không cáp, không creds), (cáp, không creds), (creds, không cáp), (creds, cáp). | Đi đúng nhánh FSM ở bảng 4.1; relay mặc định OFF. |

---

## 10. Deliverables yêu cầu AI Codegen

1. Header public cho từng module (`app_wifi.h`, `app_eth.h`, `app_netmgr.h`, `app_mqtt.h`, `app_telemetry_buf.h`) với khai báo hàm, event và struct đã nêu.
2. Kconfig cho mọi tham số ở Phần 11.
3. Bảng log tag thống nhất và mức log cho mỗi module.
4. Unit/host test cho: backoff, bảng quyết định WAN verdict, FIFO buffer, FSM transition table.
5. Mỗi module kèm checklist AC tương ứng đã đạt trước khi sang module kế tiếp.

---

## 11. Bảng cấu hình mặc định (Kconfig / `app_config_t`)

| Tham số | Giá trị Default |
| :--- | :--- |
| `PROBE_TARGETS` | `1.1.1.1`, `8.8.8.8` |
| `PROBE_COUNT / TIMEOUT` | 3 / 1000 ms |
| `PROBE_PERIOD_ACTIVE / STANDBY / RECOVERY` | 5 s / 20 s / 2 s |
| `FAILBACK_OK_COUNT / PERIOD` | 5 / 3 s |
| `BACKOFF_BASE / MAX / FLOOR` | 1 s / 60 s / 200 ms |
| `NET_CONNECT_TIMEOUT` | 30 s |
| `NET_LOST_INTERLOCK` | 300 s |
| `BLE_PROV_TIMEOUT` | 180 s |
| `BTN_PROV_HOLD / BTN_RESET_HOLD / REARM_WINDOW / DEBOUNCE` | 5 s / 5 s (lần nhấn thứ hai) / 2 s / 50 ms |
| `TELEMETRY_SLOTS / SLOT_SIZE / FLUSH_GAP` | 50 / 256 B / 100 ms |
| `W5500_VERSIONR_PERIOD / RETRY / RESET_LIMIT` | 5 s / 3 lần / 3 lần mỗi giờ |
| `WDT_NET_TIMEOUT` | 30 s |
| `RELAY_BOOT_STATE` | OFF |
