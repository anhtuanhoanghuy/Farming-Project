Requirements & System Architecture Specification: Aquaculture pond monitoring controller - ESP32-S3 Controller

# 1. Primary Goals

Deterministic High Reliability: Vận hành liên tục 24/7 trong môi trường công nghiệp, tự khôi phục sau sự cố mạng/cảm biến/sụt áp mà không treo vi điều khiển.
Seamless Integration: Cung cấp giao thức truyền nhận JSON chuẩn hóa qua MQTT (Telemetry/Command/Ack) giúp các hệ thống dễ dàng phân tích và hạ lệnh điều khiển.
Network Redundancy & Zero-Downtime Switching: Đảm bảo đường truyền luôn thông suốt với cơ chế Failover/Failback tự động giữa Ethernet SPI (W5500) và Wi-Fi Station.
BLE Provisioning & Mobile App Lifecycle Control: BLE provisioning chỉ nhận SSID, password, user_id và only_use_ethernet. Sau khi kết nối, cấu hình cảm biến, điều khiển tải, hiển thị dữ liệu và xem lỗi hệ thống được thực hiện qua MQTT hoặc các endpoint quản trị được bảo vệ.
AI Self-Coding Optimization: Tất cả Data Structures, State Machines, Input/Output Control, Module Responsibilities, Message Schemas, Task Entry Logics và Design Rules được định nghĩa ở mức cực kỳ chi tiết (C Structs / FreeRTOS Queues / Standardized Interfaces) để các công cụ AI Codegen có thể tự động sinh code ESP-IDF v5.x theo đúng kiến trúc.

Native USB Firmware Update: Hỗ trợ nạp code trực tiếp thông qua cổng Native USB (USB-Serial/JTAG Controller tích hợp trên ESP32-S3, dùng esptool/idf.py flash; không dùng USB DFU) tiện lợi cho việc bảo trì thực tế.
Secure Boot V2 & Flash Encryption (Chip Locking, release gate cho production): Bản phát triển hiện tại tắt các tính năng này; bắt buộc bật trước khi xuất xưởng. Kích hoạt cơ chế khóa chip bảo mật cao cấp của ESP32-S3. Chỉ cho phép nạp và chạy các image firmware có metadata và digital signature hợp lệ được ký mã hóa riêng cho board; vô hiệu hóa hoàn toàn việc đọc trộm firmware từ flash hoặc nạp các mã độc chưa được verify.

Sử dụng 1 file pipline để các AI agent biết ngữ cảnh của nhau như tiến độ công việc, các công việc đang làm trong lúc Code, Test, Review mà không cần hỏi lại
# 2. System Context & Interface Mapping

+-----------------------------------------------------------------------------------+

| MOBILE APP |

| (BLE Protocomm Custom Endpoints / MQTT Telemetry & Command Topics) |

+----------------------------------------+------------------------------------------+

|

v

+-----------------------------------------------------------------------------------+

| ESP32-S3-WROOM-1U MCU |

| |

| [ CORE 0: Network & Connectivity ] | [ CORE 1: Sensing, Control & System ] |

| - app_network (ETH W5500 / Wi-Fi) | - app_modbus (RS485 Polling Engine) |

| - app_mqtt (Client / Sub / Pub) | - app_control (Relay / Safety Interlock)|

| - app_ble_prov (Config / Full Control)| - app_sysmon (WDT / Memory / Error Blink)|

| - Native USB (DFU & Serial/JTAG) | - app_nvm (NVS Read/Write/Reset) |

+-------------------+---------------------+--------------------+--------------------+

| |

v v

+---------------------------------------+ +----------------------------------------+

| HARDWARE NETWORKS | | HARDWARE PERIPHERALS |

| - W5500 Ethernet SPI (SCK, MOSI, | | - RS485 Transceiver (DE/RE, TX, RX) |

| MISO, CS, INT, RST) | | + SHT40 (Temp/Humidity) |

| - Wi-Fi 802.11 b/g/n (U.FL Antenna) | | + Dissolved Oxygen (DO - Reg 0x0002)|

| - Native USB (GPIO 19/20 - D-/D+) | | + pH Sensor (Reg 0x0000) |

| | | - Relay Outputs (GPIO Control) |

| | | - Status LEDs (WiFi, ETH, Load, Err) |

| | | - Soft-RESET Push Button (GPIO Input) |

+---------------------------------------+ +----------------------------------------+

# 3. Detailed Module Specification (File-by-File Functions)

Hệ thống được chia thành 7 components độc lập trong kiến trúc ESP-IDF, mỗi component chịu trách nhiệm rõ ràng về Input, Output và API công khai:
## 3.1 main (Application Entry Point)

Mục đích: Điểm khởi chạy chính của chương trình, tạo các tài nguyên dùng chung (FreeRTOS Mutexes, Event Groups, Queues) và ghim Task vào từng Core.
Files:
`main/main.c`: Khởi tạo NVS, gọi hàm init của từng module, tạo các FreeRTOS Tasks pinned to cores.
`main/main_data_types.h`: Chứa toàn bộ Data Structures, Enums, Bitmask Lỗi và Queue Handles dùng chung toàn hệ thống.
## 3.2 app_network (Network & Failover Management)

Mục đích: Quản lý song song Ethernet SPI (W5500) và Wi-Fi Station, thực hiện tự động chuyển đổi đường truyền khi gặp sự cố.
Failover Logic: Theo `technical_requirements_network_failover_FINAL.md`: probe Active mỗi 5 s, Standby 20 s, Recovery 2 s; mất cáp ETH chuyển Wi-Fi < 5 s (AC-01), WAN lỗi âm thầm chuyển ≤ 10 s (AC-02). Hệ thống giữ OPERATIONAL khi còn một đường WAN OK. Chỉ khi mất cả hai đường mới set SYS_ERR_NET_LOST và chuyển sang STATE_NET_LOST.
WAN verdict hiện dựa trên ICMP probe tới các target cấu hình; broker-only outage không được dùng để kết luận WAN FAIL và không tự kích hoạt failover. TCP probe tới MQTT broker không thuộc phạm vi bắt buộc.
Files:
`components/app_network`/include/app_network.h: Khai báo API kết nối, chuyển đổi interface và getter trạng thái mạng.
`components/app_network`/app_network.c: Implement driver W5500, Wi-Fi STA, Event Loop Handler và WAN probe check Internet.
Chức năng chính:
1. Khởi tạo SPI Master Driver kết nối chip W5500.
2. Khởi tạo Wi-Fi Station stack với credentials từ NVM.
3. Kích hoạt Failover Logic: Ưu tiên Ethernet, khi Ethernet Down tự chuyển Route Default sang Wi-Fi, khi Ethernet UP tự quay về Ethernet.
4. Chỉ phát `SWITCH_DONE` sau khi default netif đã đổi thành công. Nếu interface đích có DNS IPv4 thì cập nhật và xác minh DNS; nếu không có, giữ DNS toàn cục hiện tại và vẫn cho phép chuyển route. Lỗi đổi route hoặc cập nhật DNS phải rollback trước khi cho MQTT restart.
## 3.3 app_mqtt (MQTT Communication & Command Gateway)

Mục đích: Quản lý MQTT Client, gửi Telemetry, gửi phản hồi (ACK), nhận lệnh điều khiển Tải và nhận cấu hình thay đổi từ app. QoS 1 cho Command/ACK, QoS 0 cho Telemetry.
Files:
`components/app_mqtt`/include/app_mqtt.h: Khai báo API khởi chạy MQTT Client, publish telemetry/status.
`components/app_mqtt`/app_mqtt.c: Implement esp-mqtt, parse JSON command qua cJSON, xử lý reconnect backoff.
Chức năng chính:
1. Duy trì kết nối MQTT Client an toàn (TCP/TLS). Duy trì mqtt_client_task. Nếu mất Broker, kích hoạt Event SYS_ERR_MQTT_BROKER.

2. Dùng `user_id` và `device_id` để định tuyến topic; subscribe `v1/{user_id}/devices/{device_id}/commands` và `v1/{user_id}/devices/{device_id}/config/set`.
3. Publish telemetry lên `v1/{user_id}/devices/{device_id}/telemetry`; publish ACK lên `v1/{user_id}/devices/{device_id}/ack` và trạng thái lên `v1/{user_id}/devices/{device_id}/status`.
4. Parse lệnh nhận được và đẩy thông điệp vào `load_cmd_queue` hoặc `config_cmd_queue`.
5. Contract payload điều khiển tải dùng chung với mobile app nằm trong `json_payoad.md`: bật/tắt, chu kỳ bật/tắt theo phút, quyền `enabled`, lịch tuần UTC và rule bật/tắt theo điều kiện cảm biến.
## 3.4 app_modbus (RS485 Modbus RTU Polling Engine)

Mục đích: Đọc dữ liệu từ các cảm biến công nghiệp qua giao thức Modbus RTU RS485 và cho phép tùy biến thông số cảm biến.
Files:
`components/app_modbus`/include/app_modbus.h: Định nghĩa API khởi tạo/poll, đọc một slot, cập nhật cấu hình và suspend/resume.
`components/app_modbus`/app_modbus.c: UART1 RS485 half-duplex qua RTS/DE-RE, CRC16 Modbus RTU, đọc và giải mã thanh ghi.
Chức năng chính:
1. Điều khiển chiều DE/RE bằng RTS của UART1; dùng GPIO/UART mapping trong `main/app_pins.h`.
2. Capacity firmware: tối đa 4 interface RS485 và 1 interface cảm biến analog 4-20 mA. Capacity GPIO là 4 DI và 4 DO; các giá trị được định nghĩa tập trung trong `main/defines.h`. `APP_LOAD_COUNT` dùng chung capacity 4 DO cho bốn relay/load.
3. Poll tuần tự 4 slot RS485 theo cấu hình NVS; SHT40 dùng Holding `0x0000–0x0001` (độ ẩm `Uint16/10`, nhiệt độ `Int16/10`); DO dùng Holding `0x0000–0x0005` gồm saturation (`0x0000–1`), concentration (`0x0002–3`) và nhiệt độ (`0x0004–5`), ba giá trị Float32 big-endian; pH dùng Holding `0x0000–0x0001` (pH `Uint16/100`, nhiệt độ `Int16/10`). Chi tiết theo register map transmitter đính kèm trong `requirement_sensor.md`.
4. Cho phép thay đổi Slave ID phía host, Name và Bật/Tắt (Enable/Disable) từng cảm biến qua MQTT. Baudrate chưa hỗ trợ qua MQTT.
5. Mỗi cycle (5 s, start-to-start) retry tối đa 3 lần khi timeout/CRC/lỗi frame, timeout mỗi request 200 ms; thất bại → `valid=false`, `consecutive_fail_count++`. Hybrid Circuit Breaker: ≥ 5 cycle lỗi liên tiếp (~25 s) → sensor `OFFLINE`, set `SYS_ERR_MODBUS_TIMEOUT`; khi OFFLINE không gửi frame, vẫn phát slot `valid=false, error="offline"` mỗi cycle và probe lại mỗi 10 s (hoặc ngay khi có cấu hình mới/đổi Slave ID). Probe thành công → reset đếm, về ONLINE. Khi mọi sensor enabled đều ONLINE → xóa `SYS_ERR_MODBUS_TIMEOUT`. Cô lập lỗi từng sensor, kiểm tra dải đo, phát `sensor_cycle_t`; E-STOP tự suspend polling. Analog 4-20 mA và DI là capacity tương lai, chưa có runtime driver.
## 3.5 app_control (Actuator & Relay Management)

Mục đích: Điều khiển bật/tắt 4 đầu ra GPIO Tải (Relays/SSRs) và quản lý cơ chế bảo vệ an toàn (Safety Interlock).
Files:
`components/app_control`/include/app_control.h: API điều khiển Relay, cài đặt Timer tự ngắt.
`components/app_control`/app_control.c: GPIO owner, Core-1 control task with monotonic deadlines for auto-off/cycles and UTC minute scheduler.
Chức năng chính:
1. Sở hữu duy nhất GPIO39–42 (DO0–DO3, active-HIGH; LOW=OFF); cấu hình LOW trước khi task bắt đầu và không khôi phục output ON khi boot.
2. Nhận `SET_STATE`/`SET_LOAD_CYCLE`; hỗ trợ `duration_min`, auto-off, cặp delay/duration một lần và ACK sau khi command được áp dụng.
3. Enforce `load_control_cfg_t.enabled`, per-load UTC weekly schedule or sensor conditions, interlock và ưu tiên E-STOP; mọi thay đổi output phát `load_changed`.
4. E-STOP tắt relay, hủy cycle, latch qua key NVS riêng `estop`, đặt `BIT_SYS_ESTOP` để P4 suspend sensor polling. Release không tự bật tải.
5. Safety Interlock: `app_mqtt` báo mất/kết nối lại kênh; `app_control` tắt tải sau `safety_timeout_s`, không tự bật lại khi mạng phục hồi.

## 3.6 app_ble_prov (BLE Provisioning & App Config Management)

Mục đích: Kích hoạt BLE Protocomm Service để provision thông tin mạng và định danh thiết bị. Chỉ chạy ở `STATE_BLE_PROV`. Sử dụng NimBLE, Security sec1. Endpoint `prov-config` chỉ nhận `ssid`, `password`, `user_id` và `only_use_ethernet`; không nhận MQTT broker URL, port, username hoặc password. Đóng kết nối và dừng BLE sau khi nhận cấu hình hợp lệ để chuyển qua `STATE_NET_CONNECTING`.
Files:
`components/app_ble_prov`/include/app_ble_prov.h: Khai báo API kích hoạt/dừng BLE Service.
`components/app_ble_prov`/app_ble_prov.c: Handlers cho provisioning/runtime endpoints của Protocomm (`prov-config`, `prov-status`, `wifi-scan`).
Chức năng chính:
1. Cung cấp endpoint `prov-config` với đúng bốn trường `ssid`, `password`, `user_id`, `only_use_ethernet` theo schema tại mục 7. `only_use_ethernet=true` buộc tắt Wi-Fi; `false` cho phép cơ chế Ethernet/Wi-Fi đã quy định. BLE chỉ chạy trong `STATE_BLE_PROV`; sau khi provision thành công, dừng BLE và chuyển sang `STATE_NET_CONNECTING`.
## 3.7 app_nvm (Non-Volatile Storage Management)

Mục đích: Lưu trữ và đọc an toàn các thông số cấu hình hệ thống vào Flash (NVS) và xử lý Nút bấm Factory Reset. NVS dùng namespace 'app_cfg', versioning CRC32 để hỗ trợ migration.
Files:
`components/app_nvm`/include/app_nvm.h: API đọc/ghi Struct Cấu hình (app_config_t), Reset Flash.
`components/app_nvm`/app_nvm.c: Thư viện nvs_flash, factory reset NVS (nút bấm do `app_sysmon` giám sát, xem `requirement_user_reset_button.md`).
API dùng chung: `app_nvm_init()`, `app_nvm_load_config()`, `app_nvm_save_config()`, `app_nvm_validate_config()`, `app_nvm_set_default_config()` và `app_nvm_factory_reset()`. Caller gọi init trước các API NVM; load điền defaults trước rồi mới đọc dữ liệu persisted.
Chức năng chính:
1. Đọc/Ghi cấu hình provisioning (`ssid`, `password`, `user_id`, `only_use_ethernet`), sensor và per-load control/schedule vào NVS. `user_id` và `only_use_ethernet` phải được lưu để giữ định tuyến MQTT/chính sách mạng. Broker MQTT không đến từ `prov-config`.
2. Nút User (GPIO4, active low) do `sysmon_task` trong `app_sysmon` giám sát: giữ >= 5 giây, nhả, rồi nhấn giữ lại 5 giây trong vòng 2 giây -> khóa tải, xóa toàn bộ NVM, reboot về chế độ BLE Provisioning; giữ >= 5 giây, nhả và không nhấn lại trong 2 giây -> `NET_CMD_START_BLE_PROV_RUNTIME` (chỉ provisioning); nhấn nhanh 2 lần -> bật/tắt in log (`PRINT_LOG`).
3. Dùng namespace `app_cfg`, key `config`; lưu một blob gồm magic, schema version, payload size, CRC-32/IEEE và `app_config_t`. Ghi blob bằng một `nvs_set_blob()`/`nvs_commit()` để cập nhật config bằng một commit. Khi đổi layout `app_config_t`, phải tăng schema version.
4. `app_nvm_init()` xử lý `ESP_ERR_NVS_NO_FREE_PAGES` và `ESP_ERR_NVS_NEW_VERSION_FOUND` bằng erase/re-init NVS. Lỗi init khác được trả về cho caller.
5. Config mặc định: credential/user_id rỗng, Ethernet-only=false, sensor disabled, tên load mặc định; safety timeout 300 giây là provisional cho đến khi policy an toàn được chốt. `app_nvm_load_config()` luôn điền defaults trước; key chưa có (`ESP_ERR_NVS_NOT_FOUND`), CRC sai hoặc schema không hỗ trợ trả lỗi rõ ràng và giữ defaults. Schema version không hỗ trợ không bị tự động xóa/ghi đè; chỉ thêm migrator khi có format cũ cần duy trì.
6. `app_nvm_validate_config()` kiểm tra string termination, offset hữu hạn và Slave ID hợp lệ/không trùng trên các RS485 sensor đang bật. Endpoint provisioning vẫn chịu trách nhiệm kiểm tra các trường mạng bắt buộc trước khi gọi save.
7. E-STOP dùng key NVS riêng `estop` (u8); `app_config_t` schema v3 lưu lịch và rule cảm biến. `NOT_FOUND` nghĩa là chưa latch. Read lỗi khác `NOT_FOUND` phải fail-safe latch và set `SYS_ERR_NVM_FAIL`.
Nút RESET (`app_sysmon`):
- Giữ < 5s (và không phải 2 lần nhấn nhanh): không tác dụng (Debounce 50 ms, bỏ qua).
- Nhấn nhanh 2 lần (mỗi lần < 0,8 s, cách nhau ≤ 0,5 s): bật/tắt in log ứng dụng (`PRINT_LOG`, `app_log`).
- Giữ >= 5s rồi nhả: chỉ LED_WIFI và LED_ETH nhấp nháy 2 Hz từ mốc 5s; LED_ERROR giữ trạng thái hiện tại. Sau 2 s không nhấn lại -> BLE Provisioning Runtime; trong phiên BLE, LED_WIFI và LED_ETH tiếp tục nhấp nháy, hết phiên trở về hiển thị theo kết nối thực tế. Không xóa dữ liệu. Nếu đổi Wi-Fi đang hoạt động, kết nối Wi-Fi sẽ gián đoạn ngắn và MQTT tự kết nối lại; tải vẫn tiếp tục vận hành.
- Sau lần giữ >= 5s, nhấn lại trong vòng 2 s và giữ 5s (thực thi ngay, không chờ nhả): tất cả LED sáng 1 giây, tắt 1 giây, lặp lại một lần; 4 relay LOW, xóa NVS, rồi khởi động lại vào provisioning. Sau hard reset, bỏ hiệu ứng sáng 2 giây lúc boot để LED_WIFI/LED_ETH bắt đầu nhấp nháy provisioning.
Logging: mọi thao tác quan trọng (init, deinit, start/stop, reconnect, failover, ...) in qua `PRINT_LOG`/`ESP_LOGx` của `app_log.h`, chỉ in khi người dùng đang bật log (mặc định tắt, `CONFIG_APP_LOG_DEFAULT_ENABLED`). `ESP_LOGE` luôn in.
## 3.8 app_sysmon (System Diagnostics, Watchdog & LED Engine)

Mục đích: Giám sát sức khỏe vi điều khiển, quản lý Task Watchdog (TWDT) và điều khiển LED hiển thị trạng thái / báo lỗi. TWDT: Kích hoạt 10s. Đăng ký các task: sensor_acquisition_task, net_mgmt_task, mqtt_client_task, và load_control_task. LED_ERROR tắt khi bình thường, nhấp nháy 2Hz với lỗi/cảnh báo không nghiêm trọng (mạng, broker, cảm biến, tải), sáng liên tục với lỗi nghiêm trọng (NVM, phần cứng, khởi tạo, cấp phát, E-STOP). Mọi lỗi được đưa vào error mask MQTT để gửi khi kết nối cho phép. Tích hợp ESP-IDF Brownout Detector (tự reboot khi sụt áp).

Files:
`components/app_sysmon`/include/app_sysmon.h: API cập nhật Error Mask, đăng ký WDT, điều khiển LED.
`components/app_sysmon`/app_sysmon.c: Implement FreeRTOS Software Timer nhấp nháy LED, Task Watchdog Timer, kiểm tra Free Heap.
Chức năng chính:
1. Đăng ký các task hệ thống vào Task Watchdog Timer (TWDT).
2. Hiển thị trạng thái LED:
LED_WIFI: Tắt khi Wi-Fi mất kết nối, sáng khi đã kết nối; nhấp nháy đồng bộ 2Hz với LED_ETH trong provisioning.
LED_ETH: Tắt khi Ethernet mất kết nối, sáng khi đã kết nối; nhấp nháy đồng bộ 2Hz với LED_WIFI trong provisioning.
LED_LOAD: Không có GPIO riêng; LED tải do phần cứng relay tự sáng theo chân GPIO relay.
LED_ERROR: Tắt khi không lỗi; nhấp nháy 2Hz cho lỗi/cảnh báo không nghiêm trọng; sáng liên tục cho lỗi nghiêm trọng. Lỗi nghiêm trọng ưu tiên nếu đồng thời có cảnh báo.
`SYS_ERR_NVM_FAIL` chỉ set khi thao tác lưu trữ thật sự thất bại (không tính lỗi validate payload); xóa khi một lần ghi cấu hình kế tiếp commit thành công và đọc lại khớp. Lỗi dai dẳng thì giữ cờ.

# 4. Complete C Data Structures & Bitmasks

File ``main/main_data_types.h`` định nghĩa toàn bộ kiểu dữ liệu chuẩn cho AI Auto-Coding:
#ifndef MAIN_DATA_TYPES_H
#define MAIN_DATA_TYPES_H

#include <stdint.h>
#include <stdbool.h>
#include "defines.h"

// 1. Trạng thái giao diện Mạng
typedef enum {
NET_IF_NONE = 0,
NET_IF_ETH,
NET_IF_WIFI
} net_interface_t;

// 2. Bitmask Mã Lỗi Hệ Thống
typedef enum {
SYS_ERR_NONE = 0,
SYS_ERR_MODBUS_TIMEOUT = (1 << 0), // Lỗi giao tiếp Modbus RS485 (cảnh báo)
SYS_ERR_NET_LOST = (1 << 1), // Mất kết nối Mạng (cảnh báo)
SYS_ERR_MQTT_BROKER = (1 << 2), // Mất kết nối MQTT Broker (cảnh báo)
SYS_ERR_NVM_FAIL = (1 << 3), // Lỗi đọc/ghi Flash NVM (nghiêm trọng)
SYS_ERR_SENSOR_OUT_RANGE = (1 << 4), // Dữ liệu cảm biến ngoài ngưỡng (cảnh báo)
SYS_ERR_ETH_INIT = (1 << 5), // Lỗi khởi tạo/lỗi phần cứng Ethernet (nghiêm trọng)
SYS_ERR_INIT_FAILURE = (1 << 6), // Lỗi khởi tạo subsystem/task (nghiêm trọng)
SYS_ERR_RESOURCE_ALLOC = (1 << 7), // Lỗi cấp phát RTOS/tài nguyên (nghiêm trọng)
SYS_ERR_LOAD_OUTPUT_DO1 = (1 << 8), // Lỗi GPIO tải DO1 (cảnh báo)
SYS_ERR_LOAD_OUTPUT_DO2 = (1 << 9), // Lỗi GPIO tải DO2 (cảnh báo)
SYS_ERR_LOAD_OUTPUT_DO3 = (1 << 10), // Lỗi GPIO tải DO3 (cảnh báo)
SYS_ERR_LOAD_OUTPUT_DO4 = (1 << 11) // Lỗi GPIO tải DO4 (cảnh báo)
} sys_error_code_t;

typedef enum {
SENSOR_SHT40 = 0,
SENSOR_DO,
SENSOR_PH,
SENSOR_ANALOG_4_20MA
} sensor_type_t;

typedef enum {
SENSOR_INTERFACE_RS485 = 0,
SENSOR_INTERFACE_ANALOG_4_20MA
} sensor_interface_type_t;

// 3. Cấu hình Chi tiết cho từng Cảm biến Modbus
typedef struct {
uint8_t slave_id; // Địa chỉ Modbus Slave ID (1-247)
sensor_type_t sensor_type;
char name[32]; // Tên gợi nhớ Cảm biến (cho phép sửa qua App)
bool enabled; // Trạng thái Bật/Tắt đọc cảm biến này
} modbus_sensor_cfg_t;

typedef struct {
char name[32];
bool enabled;
} analog_4_20ma_sensor_cfg_t;

typedef struct {
bool enabled;
uint8_t sensor_id; // 1..5: RS485 slots 0..3, analog slot 0
uint8_t op; // lt, lte, eq, gte, gt
float threshold;
} load_sensor_condition_t;

typedef struct {
bool enabled;
bool schedule_enabled;
uint8_t days_mask; // bit 0 Monday through bit 6 Sunday
uint16_t on_minute_utc; // minutes since 00:00 UTC, 0..1439
uint16_t off_minute_utc;
load_sensor_condition_t on_condition;
load_sensor_condition_t off_condition;
} load_control_cfg_t;

// 4. Cấu hình Tổng thể Lưu trữ trong NVM (NVS Flash)
typedef struct {
// WiFi & Network Config
char wifi_ssid[33]; // Up to 32 SSID bytes plus NUL
char wifi_password[64];
char user_id[37];
bool only_use_ethernet;

// Sensor config capacity: 4 RS485 + 1 analog 4-20 mA
modbus_sensor_cfg_t rs485_cfg[APP_RS485_INTERFACE_COUNT];
analog_4_20ma_sensor_cfg_t analog_4_20ma_cfg[APP_ANALOG_4_20MA_INTERFACE_COUNT];

// Actuators / Loads Config
char load_name[4][32]; // Tên gọi gợi nhớ cho tối đa 4 tải
load_control_cfg_t load_control[APP_LOAD_COUNT];
uint32_t safety_timeout_s;// Thời gian ngắt tải an toàn khi mất mạng (giây)
} app_config_t;

// Legacy scalar sensor_data_t is retained only while older producers migrate.
// MQTT and sensor_data_queue use sensor_cycle_t: up to 5 samples, each identified by
// interface_type/interface_index and carrying sensor_type, valid/error, v1/v2.

// 6. Structure Lệnh Điều khiển Tải (từ MQTT / App)
typedef enum { ORIGIN_INTERNAL = 0, ORIGIN_MQTT, ORIGIN_BLE } cmd_origin_t;
typedef enum { LOAD_COMMAND_SET_STATE = 0, LOAD_COMMAND_TIMED_CYCLE, LOAD_COMMAND_SET_ALL_OFF, LOAD_COMMAND_EMERGENCY_STOP, LOAD_COMMAND_EMERGENCY_RELEASE } load_command_kind_t;
typedef enum { LOAD_CYCLE_NONE = 0, LOAD_CYCLE_ON_THEN_OFF, LOAD_CYCLE_OFF_THEN_ON } load_cycle_mode_t;

typedef struct {
char cmd_id[37]; // UUID command plus NUL
cmd_origin_t origin;
load_command_kind_t kind;
load_cycle_mode_t cycle_mode;
uint8_t load_id; // ID Tải (1, 2, ...)
bool target_state; // true = BẬT, false = TẮT
bool set_all_off;
uint32_t duration_sec; // Thời gian đếm lùi tự động tắt (0 = vĩnh viễn)
uint32_t duration_min; // SET_STATE: ưu tiên field phút mới; 0 = không tự tắt
uint16_t on_delay_min;
uint16_t off_delay_min;
uint16_t duration; // phút; 0 = không đổi trạng thái lần hai
} load_command_t;

typedef enum { LOAD_ACK_OK = 0, LOAD_ACK_INVALID, LOAD_ACK_INTERLOCK, LOAD_ACK_INTERNAL, LOAD_ACK_FORBIDDEN, LOAD_ACK_EMERGENCY_ACTIVE } load_ack_result_t;
typedef struct {
char cmd_id[37];
cmd_origin_t origin;
uint8_t load_id;
load_ack_result_t result;
bool state_after;
uint32_t remaining_s;
uint32_t duration_min;
load_cycle_mode_t cycle_mode;
uint16_t on_delay_min, off_delay_min, duration;
bool emergency_active, emergency_changed;
uint8_t loads_off;
} load_ack_t;

// 7. Structure Cập nhật Cấu hình (từ App BLE / MQTT)
typedef struct {
char cmd_id[37];
cmd_origin_t origin;
enum {
CFG_CMD_UPDATE_NETWORK,
CFG_CMD_UPDATE_SENSOR,
CFG_CMD_UPDATE_LOAD_NAME,
CFG_CMD_UPDATE_LOAD_CONTROL
} type;
union {
struct {
char ssid[33];
char password[64];
char user_id[37];
bool only_use_ethernet;
} net_info;
struct {
sensor_interface_type_t interface_type;
uint8_t interface_index; // 0-based index within the selected interface type
sensor_type_t sensor_type;
uint8_t new_slave_id;
char new_name[32];
bool enabled;
} sensor_info;
struct {
uint8_t load_id;
char new_name[32];
} load_info;
struct {
uint8_t load_id;
load_control_cfg_t control;
} load_control_info;
} payload;
} config_update_cmd_t;

#endif

## 4.1 Capability và Runtime Interface Model

Controller phải công bố số lượng interface tối đa do firmware hỗ trợ, không phụ thuộc phần cứng ngoại vi hiện đang kết nối. `count` là số lượng tối đa; `used` là số interface đã được cấu hình. Mobile UI hiển thị các interface đang dùng và chỉ hiển thị thao tác thêm khi còn capacity.

```json
{
	"capabilities": {
		"rs485": {"supported": true, "count": 4},
		"analog_4_20ma": {"supported": true, "count": 1},
		"digital_inputs": {"supported": true, "count": 4},
		"digital_outputs": {"supported": true, "count": 4},
		"loads": {"supported": true, "count": 4}
	},
	"runtime_interfaces": {
		"rs485_used": 3,
		"analog_4_20ma_used": 0,
		"loads_used": 2
	}
}
```

Khi `rs485_used` nhỏ hơn `rs485.count`, UI hiển thị một mục `Add Sensor`; khi đạt giới hạn thì ẩn thao tác thêm. Load và analog 4-20 mA UI cũng render theo capability. `sys-status` phải công bố cả `capabilities` và `runtime_interfaces`.

# 5. State & Event Model (Inputs, Outputs & Transitions)
![alt text](image.png)

Chi tiết Input / Output của từng State:
### Table 1

| State (Trạng thái) | Input Triggers (Đầu vào) | Action & Output Logic (Xử lý & Đầu ra) | Next State Transition (Chuyển trạng thái) |
| --- | --- | --- | --- |
| `STATE_INIT` | System Power On / Reset | Khởi tạo Hardware: GPIO, NVS, UART RS485, SPI. Đọc app_config_t từ NVS. | - NVS rỗng/Lỗi: -> `STATE_BLE_PROV`
- NVS có cấu hình: -> `STATE_NET_CONNECTING` |
| `STATE_BLE_PROV` | Chuyển từ INIT hoặc Nhấn giữ Soft-RESET (≥ 5 s) rồi nhấn giữ lại 5 s trong vòng 2 s (Factory Reset, sau reboot) | Bật BLE Advertising. Mở 4 Custom Endpoints; `prov-config` chỉ nhận SSID, password, user_id và only_use_ethernet. | Nhận đủ provisioning config -> Lưu NVS -> Tắt BLE -> `STATE_NET_CONNECTING`. |
| `STATE_NET_CONNECTING` | Khởi động xong hoặc vừa Provisioning thành công | Kích hoạt Ethernet SPI W5500. Nếu `only_use_ethernet=true`, không bật Wi-Fi; nếu false, áp dụng chính sách failover Ethernet/Wi-Fi. LED_ETH/LED_WIFI nhấp nháy. | Nhận IP và kết nối MQTT Broker -> `STATE_OPERATIONAL`. |
| `STATE_OPERATIONAL` | Đã kết nối Mạng + MQTT | Core 0: Gửi Telemetry, nhận Command/Config.
Core 1: Đọc Modbus RS485, cập nhật Tải, Giám sát Health, cho phép App Config truy cập song song. | Mất kết nối Mạng (cả ETH & Wi-Fi) -> `STATE_FAILOVER`. |
| `STATE_FAILOVER` | Ethernet đứt cáp / Mất Wi-Fi / Mất Ping Gateway | Tự động đổi Route mặc định từ Ethernet -> Wi-Fi (hoặc ngược lại). LED_ERROR nhấp nháy 2Hz như cảnh báo mất mạng. Nếu mất kết nối > 300s -> Ngắt toàn bộ Tải (Safety Interlock). | - Kết nối khôi phục -> `STATE_OPERATIONAL`
- Nhấn giữ Soft-RESET ≥ 5s, nhả, nhấn giữ lại 5s trong vòng 2s -> `STATE_FACTORY_RESET` |
| Any State | Nút Soft-RESET: giữ ≥ 5 giây, nhả, rồi giữ lại 5 giây trong vòng 2 giây | LED_ERROR nháy dồn dập (10Hz). Gọi nvs_flash_erase(). Khởi động lại vi điều khiển. | Reboot -> `STATE_INIT` -> `STATE_BLE_PROV`. |


# 6. Deep-Dive Task Logics & Inter-Task Communications

## 6.1 Diagram Truyền Nhận Dữ Liệu giữa các Task (Inter-Task Queues)

 [ sensor_acquisition_task ] ----(`sensor_data_queue`)----> [ mqtt_client_task ] ----> (MQTT Telemetry)
|
[ App Endpoints ] ----(`config_cmd_queue`)-----> [ app_nvm / Tasks ]
| |
+------------------(`load_cmd_queue`)-------> [ load_control_task ] ----> (GPIO Relays)
^
[ mqtt_client_task ] ----(`load_cmd_queue`)-----------------+

- sensor acquisition task (Core 1, Priority 5, Stack 4096): Poll tối đa 4 RS485 interface đã bật; analog 4-20 mA và DI là capacity tương lai chưa có runtime. Mỗi mẫu phải nhận diện interface để phân biệt nhiều sensor cùng loại.
- load_control_task (Core 1, Priority 7, Stack 4096): Nhận lệnh điều khiển.
- net_mgmt_task (Core 0, Priority 6, Stack 8192): Xử lý Failover ETH/WiFi.
- mqtt_client_task (Core 0, Priority 5, Stack 6144): Sub/Pub MQTT.
## 6.2 Chi tiết Logic Thực Thi của Các Task Chính

sensor acquisition task (Core 1, Priority 5):
Với từng cấu hình RS485 được bật trong `rs485_cfg[APP_RS485_INTERFACE_COUNT]`: lock `modbus_uart_mutex`, đọc sensor theo loại đã cấu hình, kiểm tra CRC/timeout, sau đó unlock mutex.
Đọc cấu hình analog 4-20 mA nếu được bật; cách lấy mẫu và quy đổi phụ thuộc đặc tính điện/ADC được chốt ở P0.
Lỗi một interface chỉ đánh dấu mẫu/interface đó invalid, không bỏ qua dữ liệu hợp lệ từ các interface khác.
Đẩy một chu kỳ `sensor_cycle_t` có interface identity vào `sensor_data_queue`; payload hỗ trợ tối đa 5 sensor interface. `sensor_data_queue` phần tử là struct copy, không chuyển con trỏ.
Gọi vTaskDelay(pdMS_TO_TICKS(2000)).
load_control_task (Core 1, Priority 7):
Đợi thông điệp `load_command_t` từ `load_cmd_queue` (timeout 100 ms), kiểm tra quyền `app_config_t.load_control[load_id-1].enabled`, interlock và command kind trước khi điều khiển relay.
`SET_STATE` đổi relay ngay; `duration_sec > 0` tự tắt theo legacy contract. `TIMED_CYCLE` chạy cặp ON→OFF hoặc OFF→ON tính bằng phút. Lệnh cycle mới hủy cycle đang chờ của cùng tải. Lịch tuần đọc từ `load_control_cfg_t`, dùng UTC; khi thời gian chưa hợp lệ thì chưa chạy lịch. Sensor ON/OFF rules được xét trên sample hợp lệ mới, dùng `sensor_id` và giá trị chính `v1`; lịch và rule cảm biến loại trừ nhau. Cycle/auto-off tay được ưu tiên; Interlock/E-STOP chặn mọi hành động ON.
Khi `enabled=false`, tắt tải ngay, hủy timer/cycle, lịch và rule sensor; từ chối điều khiển tải cho đến khi enable lại. `SET_ALL_OFF` luôn được phép.
Tạo thông điệp ACK gửi lại MQTT Task khi lệnh có `origin=MQTT`, kèm mode và cặp phút đã thực thi.
Kiểm tra Safety Interlock: nếu mất kênh điều khiển quá `safety_timeout_s`, ép toàn bộ GPIO tải về mức an toàn.

Đồng hồ chuẩn dùng C time API (`time()`/`gmtime_r()`). SNTP đồng bộ khi có Internet và refresh mỗi giờ (`CONFIG_LWIP_SNTP_UPDATE_DELAY=3600000`); hệ thống duy trì giờ giữa các lần đồng bộ. Lịch tuần của từng tải được lưu trong NVS.
net_mgmt_task & Failover Engine (Core 0, Priority 5):
Lấy trạng thái Link của PHY Ethernet W5500.
Nếu Ethernet Cable Connected:
Thiết lập Ethernet làm Default Network Interface (esp_netif_set_default_netif).
Tắt Wi-Fi Station (hoặc đưa về Standby).
Cập nhật BIT_NET_ETH_CONNECTED trong sys_event_group.
Nếu Ethernet Cable Disconnected:
Kích hoạt esp_wifi_connect().
Khi Wi-Fi lấy được IP -> Thiết lập Wi-Fi làm Default Network Interface.
Cập nhật BIT_NET_WIFI_CONNECTED.
Chu kỳ Ping Gateway/Broker mỗi 5 giây. Nếu cả 2 Interface đều không Ping được -> Xóa hết Event Bits, set bit SYS_ERR_NET_LOST.

# 7. BLE Provisioning Specification

Mobile App dùng ESP-IDF Protocomm BLE chỉ cho initial/runtime provisioning. Điều khiển tải, cấu hình cảm biến và xem trạng thái sau provisioning dùng MQTT theo `json_payoad.md`:
+-----------------------------------------------------------------------------------+
| MOBILE APP BLE PROVISIONING |
+-------------------+--------------------+--------------------+---------------------+
| prov-config | prov-status | wifi-scan | |
| (network config) | (apply result) | (SSID list) | |
+-------------------+--------------------+--------------------+---------------------+

- Telemetry: `v1/{user_id}/devices/{device_id}/telemetry`
- Command Rx: `v1/{user_id}/devices/{device_id}/commands`
- ACK Tx: `v1/{user_id}/devices/{device_id}/ack`
- Config Set: `v1/{user_id}/devices/{device_id}/config/set`
- Status: `v1/{user_id}/devices/{device_id}/status`
## 1. Endpoint prov-config (Cấu hình mạng initial)

Gửi từ App (JSON Write):
{
"ssid": "Factory_AP_01",
"password": "SecretKey123",
"user_id": "pond-owner-01",
"only_use_ethernet": false
}
Phản hồi từ ESP32-S3 (bất đồng bộ, vì kết nối có thể mất ~1 phút): `prov-config` trả ngay `{"status":"IN_PROGRESS","device_id":"aabbccddeeff"}` hoặc ERROR nếu request không hợp lệ (phiên vẫn mở); tất cả phản hồi `prov-config` đều kèm `device_id`. Đây là MAC Wi-Fi STA 6 byte của chính ESP32-S3, đọc bằng `esp_read_mac(mac, ESP_MAC_WIFI_STA)`, định dạng thành 12 ký tự hex thường; không phải MAC Bluetooth, MAC của điện thoại/app hay địa chỉ BLE ngẫu nhiên. Giá trị này cũng là MQTT `device_id`. Mỗi phiên chỉ nhận một config hợp lệ. Controller thử mạng đã chọn (Only use Ethernet: chờ Ethernet có IP; ngược lại: Wi-Fi tối đa 3 lần, nếu thất bại thì kiểm tra Ethernet) rồi App đọc kết quả qua endpoint `prov-status` (ví dụ `{"state":"done","status":"SUCCESS","saved":true,"attempts":1,"device_id":"aabbccddeeff"}`; `device_id` cũng có trong trạng thái `idle` và `in_progress`). Chỉ lưu NVM khi mạng lên: SUCCESS (lưu), WARNING `ERR_WIFI_CONNECT_FAILED` khi Wi-Fi lỗi nhưng Ethernet có IP (lưu, chạy Ethernet, Wi-Fi thử lại nền), ERROR khi không có mạng nào (không lưu, controller khởi động lại phiên provisioning mới). App chỉ nên đánh dấu thiết bị đã provision trong database khi nhận `state=done` và `saved=true`; dùng MAC ESP32 này làm khóa `device_id`, không gửi Wi-Fi password/credentials lên database. Luôn gửi kết quả cho App trước, rồi mới dừng BLE (sau 2 giây), bất kể thành công hay thất bại; không reboot khi đã lưu. Endpoint `wifi-scan` (`{"start":0}` quét, `{"start":N}` phân trang) cho App lấy danh sách SSID.
Mỗi phiên BLE provisioning advertise tối đa 5 phút. Nếu hết thời gian hoặc cấu hình không được lưu, thiết bị chưa cấu hình dừng advertise và chờ giữ nút rồi nhả để mở lại, không tự reboot để tạo phiên mới. Nếu một request đã được nhận sát thời hạn, dừng advertise nhưng hoàn tất request và trả kết quả cho client đang kết nối trước khi đóng BLE.
Endpoint này chỉ chấp nhận đúng bốn trường trên. MQTT broker settings không thuộc payload provisioning và phải được cấp theo cấu hình riêng của firmware/deployment.
Transport: Protocomm NimBLE, security sec1 với Proof-of-Possession (PoP); mọi request/response của endpoint được mã hóa bởi session sec1. Tên thiết bị BLE là `PROV_ESP32_` + 3 byte cuối của BT MAC. PoP hiện là giá trị chung provisional `APP_BLE_PROV_POP`, cần thay bằng cơ chế theo thiết bị khi chốt mô hình bảo mật BLE.
Ràng buộc giá trị: `user_id` 1-36 ký tự ASCII hiển thị (đủ chứa UUID Supabase), không chứa `/`, `+`, `#`; khi `only_use_ethernet=false` thì `ssid` 1-32 byte và `password` rỗng (mạng mở) hoặc 8-63 ký tự. Lỗi trả về {"status": "ERROR", "reason": "invalid_request|invalid_json|invalid_fields|invalid_value|storage_error|already_provisioned"}. Sau khi lưu thành công, request provisioning tiếp theo bị từ chối.
Boot flow: đọc NVM; nếu có `user_id` và Wi-Fi credentials hợp lệ (hoặc `only_use_ethernet=true` với `user_id` hợp lệ) -> `STATE_NET_CONNECTING` và kết nối Wi-Fi STA với retry backoff full jitter 0.2-60 giây (spec FINAL mục 3.6); ngược lại -> `STATE_BLE_PROV` và advertise. Wi-Fi credentials chỉ lưu trong NVM `app_cfg` (Wi-Fi driver dùng storage RAM). `only_use_ethernet=true` tắt Wi-Fi và dùng Ethernet (W5500) do network FSM quản lý.
## 2. Endpoint sensor-config (Legacy, không còn là contract vận hành)

Sau provisioning, BLE chỉ dùng cho provisioning (`prov-config`, `prov-status`, `wifi-scan`). Firmware KHÔNG có endpoint BLE `sensor-config`; cấu hình cảm biến dùng MQTT `config/set` (`json_payoad.md`). Payload dưới đây chỉ giữ làm lịch sử.

Gửi từ App (JSON Write):
{
"interface_type": "rs485",
"interface_index": 0,
"sensor_type": "ph",
"slave_id": 3,
"name": "pH_Tank_A1",
"enabled": true,
}
Xử lý trên ESP32-S3: Cập nhật sensor config slot tương ứng trong RAM, gọi app_nvm_write_config(), gửi thông điệp reload cho sensor_acquisition_task. `interface_index` dùng chỉ số 0-based: RS485 từ 0 đến 3, analog 4-20 mA là 0.
## 3. Legacy `load-ctrl` endpoint (không còn là contract vận hành)

BLE không điều khiển tải sau provisioning. Payload `SET_STATE`/`new_name` cũ dưới đây chỉ được giữ làm lịch sử và MUST NOT được dùng làm contract mobile mới. Dùng MQTT topics/actions và structs trong `json_payoad.md`.

Gửi từ App (JSON Write):
{
"action": "SET_STATE",
"load_id": 1,
"state": true,
"duration_sec": 60,
"new_name": "Pump_Water_A"
}
Payload cũ không được nối vào firmware vận hành; tên tải qua `config/set type=load_name`, điều khiển qua `commands`.
## 4. Endpoint sys-status (Legacy, không còn là contract vận hành)

Firmware KHÔNG có endpoint BLE `sys-status`. Trạng thái, `capabilities`, `runtime_interfaces` và lỗi được công bố qua MQTT `snapshot`/`telemetry`/`events` (`requirement_mqtt.md`). Với analog 4-20 mA và DI, `capabilities` có `supported=true` nhưng `runtime_available=false` cho tới khi có driver. Ví dụ dưới đây chỉ giữ làm lịch sử.

Yêu cầu từ App (Read Request).
Phản hồi từ ESP32-S3 (JSON Response):
{
	"capabilities": {
		"rs485": {"supported": true, "count": 4},
		"analog_4_20ma": {"supported": true, "count": 1},
		"digital_inputs": {"supported": true, "count": 4},
		"digital_outputs": {"supported": true, "count": 4},
		"loads": {"supported": true, "count": 4}
	},
	"runtime_interfaces": {
		"rs485_used": 3,
		"analog_4_20ma_used": 0,
		"loads_used": 2
	},
"net_interface": "ETH",
"sensors": [
{"interface_type": "rs485", "interface_index": 0, "sensor_type": "sht40", "name": "Temp_Humid_Room", "temp": 29.1, "humid": 68.4, "valid": true},
{"interface_type": "rs485", "interface_index": 1, "sensor_type": "do", "name": "DO_Tank_1", "do_mg_l": 6.82, "valid": true},
{"interface_type": "rs485", "interface_index": 2, "sensor_type": "ph", "name": "pH_Tank_A1", "ph_val": 7.15, "valid": true}
],
"digital_inputs": [false, false, false, false],
"digital_outputs": [true, false, false, false],
"loads": {
"load_1": {"name": "Pump_Water_A", "state": true}
},
"errors": {
"code_mask": 1,
"messages": ["SYS_ERR_MODBUS_TIMEOUT on pH Sensor"]
}
}

# 8. Cấu hình Giao tiếp Phần cứng & Bảo mật (Secure Boot & Native USB)

## 1. Giao tiếp Ethernet W5500 (SPI Interface):

Sử dụng ESP-IDF SPI Master Driver kết nối với chip điều khiển mạng W5500 qua các đường chân phần cứng chuẩn: SPI2_HOST (FSPI), bao gồm SCLK, MOSI, MISO, chân chọn thiết bị CS, chân ngắt phần cứng INT, và chân phần cứng RST để khôi phục cứng khi W5500 treo cứng.
## Nạp Firmware qua Native USB & Chống khóa Chip (Security):

Native USB Serial/JTAG: Cấu hình chân GPIO 19 (D-) và GPIO 20 (D+) trực tiếp nối ra cổng USB Type-C/Micro của mạch. Cho phép lập trình viên nạp firmware (idf.py flash/esptool) trực tiếp bằng cổng USB Serial/JTAG tích hợp trên chip ESP32-S3 mà không cần chip chuyển đổi UART ngoài (như CH340 hay CP2102). Không dùng USB DFU.

Secure Boot V2 & Flash Encryption (release gate): Bản dev hiện tắt. Khi đóng gói sản phẩm thương mại, BẮT BUỘC bật CONFIG_SECURE_BOOT_V2_ENABLED và CONFIG_SECURE_FLASH_ENC_ENABLED trong menuconfig của ESP-IDF. Thiết bị sẽ kích hoạt khóa phần cứng (eFuse), mã hóa toàn bộ nội dung trong flash ngăn chặn hành vi đọc trộm mã nguồn qua chân JTAG/SPI, đồng thời kiểm tra chữ ký số của Firmware trước mỗi lần khởi động (chỉ cho phép chạy code được verify chuẩn xác).
# Datasheet cảm biến

Cảm biến PH
![alt text](PH-sensor.jpg)

Cảm biến oxy hòa tan DO
![alt text](DO-sensor.jpg)

Cảm biến nhiệt độ, độ ẩm không khí SHT40
![alt text](SHT40.png)

# Error Handling, Watchdogs & System Recovery

Task Watchdog Timer (TWDT):
Kích hoạt TWDT với timeout 10 giây, theo dõi cả hai idle task và bật panic để hệ thống tự reset khi timeout. Các task `sensor_acquisition_task`, `net_mgmt_task`, `mqtt_worker`, `app_control_task` và `sysmon_task` bắt buộc đăng ký thành công với TWDT và gọi `esp_task_wdt_reset()` trong mỗi vòng lặp. Nếu đăng ký thất bại, firmware không tiếp tục chạy thiếu bảo vệ mà yêu cầu restart.
System Error LED Blink Engine (`app_sysmon`):
Kiểm tra `sys_error_mask`, event E-STOP và trạng thái network định kỳ mỗi 100ms:
SYS_ERR_NONE: LED_ERROR tắt.
SYS_ERR_NET_LOST / SYS_ERR_MQTT_BROKER / SYS_ERR_MODBUS_TIMEOUT / SYS_ERR_SENSOR_OUT_RANGE / lỗi GPIO tải: LED_ERROR nhấp nháy 2Hz.
SYS_ERR_NVM_FAIL / SYS_ERR_ETH_INIT / SYS_ERR_INIT_FAILURE / SYS_ERR_RESOURCE_ALLOC / E-STOP / interlock: LED_ERROR sáng liên tục.
Mọi bit lỗi đều được báo trong snapshot/telemetry MQTT khi MQTT hoạt động; lỗi mất kết nối hoặc MQTT được gửi lại sau khi kết nối phục hồi. Lỗi nghiêm trọng ưu tiên nếu đồng thời có cảnh báo.
LED_WIFI và LED_ETH sáng khi interface tương ứng kết nối, tắt khi mất kết nối; cả hai nhấp nháy đồng bộ 2Hz trong provisioning. Khi khởi động thường tất cả LED sáng 2 giây; factory reset có chuỗi sáng 1 giây/tắt 1 giây lặp hai lần trước khi vào provisioning. LED tải do phần cứng relay tự sáng theo chân GPIO relay (không có GPIO LED_LOAD).
Memory Diagnostics:
`sysmon_task` kiểm tra `esp_get_free_heap_size()` mỗi 100ms.
Nếu Free Heap < 20KB -> Bật Cảnh báo WARNING qua USB Native Serial và đẩy log lỗi về MQTT Status Topic.

# 11. Acceptance Criteria (Verification Matrix)

### Table 2

| Test ID | Hạng mục kiểm thử | Kịch bản thực hiện (Test Procedure) | Điều kiện Đạt (Pass Criteria) |
| --- | --- | --- | --- |
| AC-01 | Core Isolation | Tăng tần suất đọc Modbus lên tối đa trên Core 1. | Mạng và MQTT trên Core 0 không bị trễ packet, latency < 50ms. |
| AC-02 | Zero-Downtime Failover | Rút dây cáp Ethernet W5500 khi đang kết nối (link-down); và rút WAN ở router khi cáp ETH vẫn cắm (silent WAN failure). | Theo `technical_requirements_network_failover_FINAL.md`: link-down → MQTT connected trên Wi-Fi < 5 s (AC-01 của spec); silent WAN failure → probe 3/3 fail và chuyển Wi-Fi ≤ 10 s (AC-02 của spec). |
| AC-03 | Modbus Fault Tolerance | Ngắt dây tín hiệu của cảm biến pH. | Sau 5 cycle lỗi liên tiếp (~25 s) pH `OFFLINE`, LED_ERROR nháy 2Hz (nếu không có lỗi nghiêm trọng/E-STOP). MQTT telemetry vẫn chứa các sample SHT40/DO hợp lệ và sample pH có `valid=false, error="offline"`, nhận diện theo `interface_type` và `interface_index`; probe lại mỗi 60 s, nối lại dây → ONLINE và xóa lỗi. |
| AC-04 | MQTT App Lifecycle Control | Dùng Mobile App kết nối qua MQTT để sửa tên cảm biến pH thành "pH_Oat_1" và đổi Slave ID cấu hình phía host. | Nhận ACK thành công sau khi cập nhật NVS; telemetry tiếp theo dùng tên và Slave ID mới. |
| AC-05 | Factory Soft-Reset | Nhấn giữ Soft-RESET 6 s, nhả, rồi nhấn giữ lại 5 s trong vòng 2 s. | NVS Flash bị xóa sạch, vi điều khiển reboot và tự nhảy vào chế độ BLE Provisioning (`STATE_BLE_PROV`). |
| AC-06 | Native USB Debugging | Cắm cổng Native USB vào máy tính mà không cần Mạch USB-UART ngoài. | Nạp firmware thành công (không cần bấm nút BOOT/EN) và đọc được toàn bộ ESP_LOG Serial Debug. |
| AC-07 | MQTT Load Control | Qua mobile app, disable/enable một tải; gửi cả hai mode `ON_THEN_OFF`/`OFF_THEN_ON`; đặt lịch UTC cho các ngày đã chọn; reboot để kiểm tra config. | Disable ép output OFF, hủy cycle/lịch và từ chối lệnh; cycle chạy đúng cặp thời gian; lịch và quyền enable được lưu/khôi phục; ACK/snapshot phản ánh đúng trạng thái. |
| AC-08 | MQTT E-STOP | Chốt E-STOP khi relay đang ON; thử lệnh bật; reboot; release có/không `confirm:true`. | Relay LOW trước ACK; latch còn sau reboot; bật bị `emergency_active`; release thiếu confirm bị từ chối, release hợp lệ không tự bật tải; sensor telemetry báo `stopped`. |
# 12. Complete ESP-IDF Component File Tree

├── CMakeLists.txt

├── partitions.csv # Định nghĩa phân vùng Flash (một app, không OTA)

├── main/

│ ├── CMakeLists.txt

│ ├── defines.h # Firmware capacities for RS485, analog, DI, and DO interfaces

│ ├── main.c # Entry point (app_main), task creation pinned to cores

│ └── main_data_types.h # Shared C Structs, Enums, Event Bits, Queue Handles

├── components/

│ ├── app_network/ # Ethernet W5500 SPI driver + Wi-Fi Station Failover Manager

│ │ ├── CMakeLists.txt

│ │ ├── include/app_network.h

│ │ └── app_network.c

│ ├── app_mqtt/ # MQTT Client, Telemetry Publish & Command Parser

│ │ ├── CMakeLists.txt

│ │ ├── include/app_mqtt.h

│ │ └── app_mqtt.c

│ ├── app_modbus/ # RS485 UART Driver, Modbus RTU Engine (SHT40, DO [0x0002], pH [0x0000])

│ │ ├── CMakeLists.txt

│ │ ├── include/app_modbus.h

│ │ └── app_modbus.c

│ ├── app_control/ # Relay GPIO Driver, Auto-off Timers, Safety Interlock

│ │ ├── CMakeLists.txt

│ │ ├── include/app_control.h

│ │ └── app_control.c

│ ├── app_ble_prov/ # BLE Protocomm Provisioning & Full App Management

│ │ ├── CMakeLists.txt

│ │ ├── include/app_ble_prov.h

│ │ └── app_ble_prov.c

│ ├── app_nvm/ # NVS Flash Management & Soft-RESET Button Handler

│ │ ├── CMakeLists.txt

│ │ ├── include/app_nvm.h

│ │ └── app_nvm.c

│ └── app_sysmon/ # Task WDT, Memory Leak Checker, LED Error Blink Engine

│ ├── CMakeLists.txt

│ ├── include/app_sysmon.h

│ └── app_sysmon.c

└── requirements.md # Standard Document for AI Auto-Coding Generator

└── pipline.md # file ngữ cảnh để mỗi AI luôn biết đang làm đến đâu

# 13. Các Điểm Cần Chốt Trước Khi Triển Khai

Các nội dung dưới đây chưa nhất quán giữa các phần của đặc tả hoặc chưa khớp với shared types P1. Không tự suy diễn contract trong lúc triển khai; cập nhật đồng thời tài liệu, `main_data_types.h` và pipeline sau khi có quyết định:

- **MQTT broker/device identity:** Development broker is `mqtt://broker.emqx.io:1883` (public, unauthenticated plaintext; development only). Broker URI/credentials come from Kconfig, not provisioning/NVS. Production requires a private TLS broker and per-device credentials. `device_id` remains the Wi-Fi STA MAC in lowercase hex.
- **Sensor schema/electrical interface:** RS485 (pH, DO, SHT40) là phạm vi runtime hiện tại. Analog 4-20 mA và 4 DI là capacity tương lai (`runtime_available=false` trong MQTT capabilities) tới khi chốt đặc tính điện/ADC, GPIO mapping và hành vi DI.
- **BLE lifecycle:** MQTT is the operational channel after provisioning; BLE is limited to initial and runtime provisioning.
- **Network timing (đã chốt):** Dùng bộ timeout của `technical_requirements_network_failover_FINAL.md` (probe 5/20/2 s, failover AC-01 < 5 s, AC-02 ≤ 10 s). Các mô tả ping 2 s / `STATE_OFFLINE` ở nơi khác là cũ.
- **WAN probing policy (đã chốt):** TCP probe tới MQTT broker không bắt buộc và không dùng làm fallback để kết luận WAN. WAN verdict hiện dùng ICMP tới các target cấu hình; trước nghiệm thu phải xác nhận mạng triển khai cho phép ICMP tới ít nhất một target. Nếu mạng chặn ICMP, cần chốt và kiểm thử một phương thức WAN độc lập với broker trước khi nghiệm thu.
