# requirement_mqtt.md — Đặc tả triển khai module `app_mqtt`

| Mục | Giá trị |
| --- | --- |
| Phiên bản | 1.0-draft |
| Ngày | 2026-10-08 |
| Dự án | Aquaculture pond monitoring controller — ESP32-S3-WROOM-1U, ESP-IDF v5.2.6 |
| Phạm vi | `components/app_mqtt` và toàn bộ điểm giao tiếp với `app_network`, `app_control`, `app_modbus`, `app_nvm`, `app_sysmon`, `main` |
| Nguồn | (1) `requirements.md` — hiện hành; (2) `pipline.md` — trạng thái code thực tế; (3) `ESP32-S3_Controller_-_Requirements___Architecture_Specification.docx` — bản v1 cũ |
| Đối tượng đọc | AI agent làm Code / Test / Review. Đọc xong tài liệu này không cần hỏi lại, trừ các mục `DECISION-REQUIRED` |

---

## 0. Cách dùng tài liệu này (dành cho AI agent)

### 0.1 Quy ước từ khóa

- **MUST / MUST NOT**: bắt buộc. Vi phạm = lỗi, review phải chặn.
- **SHOULD**: mặc định phải làm; chỉ bỏ khi có lý do ghi trong `pipline.md`.
- **MAY**: tùy chọn.

### 0.2 Nhãn trạng thái của từng quyết định

| Nhãn | Ý nghĩa |
| --- | --- |
| `[CONFIRMED]` | Đã có trong `requirements.md` / `pipline.md` hoặc đã chốt. Không tự đổi. |
| `[PROVISIONAL]` | Đang dùng tạm trong code, có thể đổi. Phải cô lập sau một hàm/Kconfig để dễ thay. |
| `[PROPOSED]` | Đề xuất của tài liệu này vì spec gốc để trống. **Áp dụng mặc định** để không bị chặn; khi chủ dự án đổi thì sửa tài liệu + code + `pipline.md` cùng lúc. |
| `[DECISION-REQUIRED]` | Cần chủ dự án quyết. Mỗi mục có "mặc định áp dụng tạm" để agent vẫn làm tiếp được. |

### 0.3 Quy tắc quy trình (kế thừa từ `pipline.md`)

1. Trước mỗi task: cập nhật mục **Active Work** trong `pipline.md` (phase P7, module `app_mqtt`, task, owner, blocker).
2. Sau mỗi hành động có ý nghĩa: ghi **Work Log** (file đã đổi, lệnh/test + kết quả, quyết định, blocker). Không gom lại ghi sau.
3. Khi bàn giao/tạm dừng: ghi rõ *next action* chính xác.
4. Không đánh dấu phase hoàn thành nếu thiếu bằng chứng ở cổng kiểm thử (mục 13).
5. Không tự suy diễn contract. Nếu gặp điểm chưa rõ không có trong tài liệu này: dừng, ghi vào `pipline.md` → Blocking Decisions, dùng mặc định an toàn nhất (hướng **an toàn = tắt tải, từ chối lệnh nghi ngờ**).
6. Mỗi thay đổi contract (JSON schema, struct, topic) phải sửa **đồng thời**: `requirement_mqtt.md`, `requirements.md`, `main/main_data_types.h`, `pipline.md`.

### 0.4 Thứ tự ưu tiên nguồn khi mâu thuẫn

`requirement_mqtt.md` (tài liệu này) > `requirements.md` > `pipline.md` (mô tả hiện thực, không phải yêu cầu) > file `.docx` (**lỗi thời, chỉ để tham khảo lịch sử**).

---

## 1. Phạm vi

### 1.1 Trong phạm vi

1. Vòng đời MQTT client: khởi động, kết nối (TCP/TLS), reconnect backoff, dừng, tắt khi factory reset.
2. Định danh: `user_id`, `device_id`, `client_id`, xây dựng topic.
3. Nhận và xử lý `commands` (điều khiển tải) và `config/set` (cấu hình cảm biến, tên tải): ghép mảnh, parse, validate, chống trùng, đưa vào queue.
4. Phát: `telemetry` (QoS 0), `ack` (QoS 1), `status` (presence, snapshot, event).
5. Đệm telemetry khi mất kết nối và xả lại khi có kết nối.
6. Phối hợp với failover mạng (dừng/khởi động MQTT theo sự kiện FSM) và cơ chế Safety Interlock (phần liên quan đến MQTT).
7. Các cờ lỗi/trạng thái liên quan: `SYS_ERR_MQTT_BROKER`, `BIT_MQTT_CONNECTED`, `BIT_TIME_VALID`.
8. Quan sát (counter, log), giới hạn tài nguyên, bảo mật kênh MQTT.
9. Kế hoạch kiểm thử và rủi ro cho riêng MQTT.

### 1.2 Ngoài phạm vi (nhưng có điểm giao tiếp được mô tả)

- Thuật toán failover/ping (thuộc `app_network`, P6). `app_mqtt` chỉ phản ứng với sự kiện FSM. **Rule D: trạng thái MQTT không bao giờ là đầu vào của quyết định failover.**
- Driver relay, timer tự ngắt, logic interlock cuối cùng (thuộc `app_control`, P5).
- Modbus RTU, giải mã thanh ghi (thuộc `app_modbus`, P4).
- BLE provisioning (thuộc `app_ble_prov`, P8). **Quyết định đã chốt: BLE chỉ dùng cho provisioning ban đầu và runtime provisioning (giữ nút ≥ 5 s, nhả, không nhấn lại). Mọi thao tác điều khiển tải, cấu hình/đọc cảm biến, xem trạng thái sau đó chỉ qua MQTT.** Do đó MQTT là kênh vận hành duy nhất và phải có đầy đủ tương đương các endpoint `sensor-config`, `load-ctrl`, `sys-status` của BLE.
- Secure Boot V2, Flash Encryption (P11) — chỉ nêu ràng buộc ảnh hưởng đến MQTT (mục 12 và 10.RZ). Không có chức năng OTA.

---

## 2. Mâu thuẫn giữa các nguồn và cách xử lý

| # | Chủ đề | Bản `.docx` (cũ) | `requirements.md` (hiện hành) | Code (`pipline.md`) | Quyết định áp dụng |
| --- | --- | --- | --- | --- | --- |
| C1 | Topic | `v1/devices/me/{telemetry,commands,ack,config/set,status}` | `v1/{user_id}/devices/{device_id}/{...}` | Dùng dạng có `user_id`/`device_id` | **Dùng dạng có `user_id`/`device_id`.** Không implement `v1/devices/me/*`. |
| C2 | Broker qua BLE | `prov-config` nhận `mqtt_url`, `mqtt_port` | `prov-config` chỉ nhận `ssid`, `password`, `user_id`, `only_use_ethernet` | Broker URI/user/pass từ Kconfig | **Broker không đến từ BLE.** Xem D-05. |
| C3 | Vòng đời BLE | Quản trị đầy đủ qua BLE | Mục 13 `requirements.md` còn ghi "cần chốt" | BLE tắt sau provisioning | **Chốt: chỉ MQTT** (xem 1.2). `requirements.md` mục 13 cần cập nhật cho khớp. |
| C4 | Điều kiện Safety Interlock | Mất MQTT / `SYS_ERR_MQTT_BROKER` / `SYS_ERR_NET_LOST` quá 300 s (mục 3.5) nhưng mục 6.2 chỉ nêu `NET_LOST` | Giữ nguyên mâu thuẫn | Timer bắt đầu khi FSM báo `NET_LOST` | **D-07** — mặc định tạm: "mất kênh điều khiển MQTT liên tục" (bao gồm mất mạng). |
| C5 | Trạng thái khi mất mạng | `STATE_OFFLINE` / `STATE_FAILOVER` | `STATE_FAILOVER` | `STATE_NET_LOST`, `STATE_MQTT_CONNECTING`, `STATE_BLE_PROV_RUNTIME` | `app_mqtt` **chỉ đọc** sự kiện FSM và event bits, không tự định nghĩa state hệ thống. |
| C6 | Payload telemetry | `sensor_data_t` scalar `ph_valid`… | Mục 13: phải chuyển sang payload có interface identity | `sensor_data_t` scalar vẫn còn | **Telemetry dùng mảng `sensors[]` có `interface_type` + `interface_index`** (8.4). AC-03 phải sửa cách đọc cờ lỗi (xem 13.6). |
| C7 | Config mạng qua MQTT | `CFG_CMD_UPDATE_WIFI_MQTT` | `CFG_CMD_UPDATE_NETWORK` còn trong struct | Parser **từ chối** config mạng | **Từ chối** (D-08). |
| C8 | Tên field JSON ↔ struct | — | JSON: `slave_id`, `name`, `state`. Struct: `new_slave_id`, `new_name`, `target_state` | — | **D-25**: cần đồng bộ hoặc ghi bảng ánh xạ (8.2.3). |
| C9 | `cmd_id[36]` | — | UUID 36 ký tự nhưng mảng 36 byte → không còn chỗ NUL | — | **D-19**: đổi thành `cmd_id[37]`. |
| C10 | Baudrate | 3.4 nói đổi được Baudrate | `modbus_sensor_cfg_t` **không có** trường baudrate | — | **D-23**: baudrate **không** hỗ trợ qua MQTT cho đến khi struct có trường này. |
| C11 | ACK "gửi lại MQTT Task / BLE Client" | Có | Có | `load_ack_t` + `load_ack_queue` có | **D-20**: thêm trường `origin`; chỉ lệnh có `origin=MQTT` mới được ACK lên MQTT. |
| C12 | Tên task | `sensor_modbus_task` | `sensor_acquisition_task` | — | Dùng `sensor_acquisition_task`. |
| C13 | Priority `net_mgmt_task` | 5 (6.2) / 6 (6.1) | 6 | 6 | 6. |
| C14 | Cảnh báo heap | "đẩy log lỗi về MQTT Status Topic" | Giữ nguyên | Chưa làm | Định nghĩa schema `event: low_heap` (8.5.3). |
| C15 | AC-04 "đổi Slave ID" | Mơ hồ: đổi địa chỉ phía host hay ghi vào thanh ghi cảm biến? | Giữ nguyên | — | **D-12**: mặc định chỉ đổi cấu hình phía host. |
| C16 | Ý nghĩa "used" của interface | — | `rs485_used` có trong `sys-status` | Không có cờ `configured` trong struct | **D-13**. |

---

## 3. Hiện trạng code `app_mqtt` (theo `pipline.md`, ngày 2026-10-08)

> Agent **MUST** đọc `components/app_mqtt/app_mqtt.c`, `app_telemetry_buffer.c`, `Kconfig` hiện có và **đối chiếu** với tài liệu này trước khi sửa. Không viết lại phần đã đúng; chỉ sửa phần lệch và bổ sung phần thiếu.

### 3.1 Đã có (build pass, **chưa kiểm chứng trên phần cứng**)

| Hạng mục | Chi tiết theo pipeline |
| --- | --- |
| esp-mqtt client | `disable_auto_reconnect`, reconnect bằng FreeRTOS software timer + `esp_mqtt_client_reconnect()` |
| Backoff | Full jitter: base 1 s, max 60 s, floor 200 ms |
| Subscribe | `commands`, `config/set` |
| Parse | Event DATA → `load_cmd_queue` / `config_cmd_queue`; hỗ trợ `SET_STATE`, `SET_LOAD_CYCLE`, config sensor/tên tải/quyền và lịch tải; config mạng bị từ chối |
| Presence | LWT + trạng thái online |
| Live telemetry | Mỗi 5 giây gửi chu kỳ cảm biến mới nhất với QoS 0 khi MQTT `ONLINE`; nếu offline hoặc outbox đầy thì đưa vào ring buffer. Task Modbus và cập nhật điều khiển tải giữ nguyên chu kỳ đọc hiện tại. |
| Status snapshot | Gửi ngay khi vào `ONLINE`, sau đó theo `CONFIG_APP_MQTT_SNAPSHOT_PERIOD_S` (mặc định 60 s). |
| Buffer telemetry | Ring tĩnh 50 × 256 B, mutex, drop-oldest; xả sau reconnect, nhịp 100 ms, mẫu live đi trước |
| Thời gian | SNTP → `BIT_TIME_VALID` kiểm soát timestamp |
| Safety timer | 300 s, starts on loss of MQTT control; on expiry calls `app_control_interlock_trip()` (app_mqtt no longer writes relay GPIO); outputs stay OFF after recovery |
| Liên kết FSM | `app_network_register_event_cb`: `SWITCH_BEGIN` → stop MQTT; `SWITCH_DONE` → start MQTT sau khi default netif đổi thành công (DNS được cập nhật nếu interface có DNS IPv4; nếu không thì giữ DNS hiện tại); `LOST` → stop MQTT (chạy trên `net_mgmt_task`) |
| Nối vào `main` | Đã gọi init/start (cần `CONFIG_APP_MQTT_BROKER_URI`) |

### 3.2 Theo dõi G1–G12

| # | Hạng mục | Trạng thái code | Trạng thái kiểm chứng / ghi chú |
| --- | --- | --- | --- |
| G1 | Publish **ACK** (từ `load_ack_queue` và kết quả config) | Implemented | Broker round-trip and queue-full behavior require target tests. |
| G2 | Publish **status**: retained presence, snapshot, event | Implemented | Snapshot still has default/unknown hardware state until P4/P5 producers update the runtime API. |
| G3 | TLS certificate verification and time gate | Implemented | TLS handshake/certificate failure behavior not tested against a private TLS broker. |
| G4 | Generic sensor payload, up to 5 identified interfaces | Implemented | P4 publishes four RS485 samples per cycle; analog producer and hardware acceptance remain pending. |
| G5 | Bounded fragmented DATA assembly | Implemented | Fragmentation and oversize fault injection pending. |
| G6 | `cmd_id` dedupe, stale timestamp and retained-message rejection | Implemented | Retained/duplicate/stale broker tests pending. |
| G7 | Kconfig for reconnect, keepalive, buffers and limits | Implemented | Build validates the selected configuration; range/fault tests pending. |
| G8 | Broker endpoint getter for optional diagnostics | Implemented | `app_mqtt_get_broker_host/port()` remains available, but broker reachability is not used as a WAN verdict or failover trigger. |
| G9 | Transfer safety interlock ownership to `app_control` (P5) | Implemented in source | MQTT timer delegates trip/clear and all relay GPIO ownership to `app_control`; interlock/hardware acceptance remains pending. |
| G10 | Real-broker, TLS and fault-injection tests | Not verified | Requires ESP32-S3 hardware and a private TLS test broker; public EMQX is plaintext development-only. |
| G11 | `config_cmd_queue` consumer and result-to-ACK path | Implemented | Main consumer validates/saves and emits correlated ACK; target persistence test pending. |
| G12 | Exact `SYS_ERR_MQTT_BROKER` set/clear policy | Implemented | Debounced while network is ready; immediate for auth/TLS errors; cleared online or for planned/network stops. |

---

## 4. Sổ quyết định (Decision Register)

| ID | Nội dung | Trạng thái | **Mặc định áp dụng tạm** | Ảnh hưởng |
| --- | --- | --- | --- | --- |
| D-01 | MQTT là kênh duy nhất cho tải, cảm biến, trạng thái sau provisioning | `[CONFIRMED]` | — | Phải có đủ lệnh/snapshot tương đương BLE |
| D-02 | 5 topic `v1/{user_id}/devices/{device_id}/{telemetry,commands,ack,config/set,status}` | `[CONFIRMED]` | — | Mục 6, 8 |
| D-03 | QoS: telemetry 0; commands/ack/config 1 | `[CONFIRMED]` | Status: presence QoS 1 retained; snapshot/event QoS 1 không retained | 8.1 |
| D-04 | `device_id` = 12 hex thường của MAC Wi-Fi STA; `client_id` = `device_id` | `[PROVISIONAL]` | Giữ | 6.1 |
| D-05 | Nguồn broker URI / username / password | `[CONFIRMED]` | Kconfig; development default `mqtt://broker.emqx.io:1883`, no credentials. Production must use a private TLS broker and per-device credentials. | 6.4, R-14 |
| D-06 | Chính sách TLS | `[DECISION-REQUIRED]` | Production: `mqtts://` + xác thực chứng chỉ server (CA bundle hoặc CA ghim). Plain `mqtt://` chỉ cho build dev (Kconfig `APP_MQTT_ALLOW_PLAINTEXT`) | 6.5 |
| D-07 | Điều kiện bắt đầu đếm Safety Interlock | `[DECISION-REQUIRED]` | **Mất kênh điều khiển MQTT liên tục ≥ `safety_timeout_s`** (gồm mất mạng, mất broker, đang failover). Lý do: nếu broker chết mà mạng còn sống thì không ai điều khiển được tải | 10.RF |
| D-08 | Config mạng (`ssid`, `password`, `user_id`, broker) qua MQTT bị cấm | `[PROPOSED]` (khớp code) | Từ chối `forbidden` | 8.2 |
| D-09 | Độ mới của lệnh: `clean_session=true`; bỏ qua message retained; `ts` tùy chọn để kiểm tra tuổi lệnh | `[PROPOSED]` (an toàn) | Áp dụng | 10.RX, 10.RL |
| D-10 | Chống trùng bằng `cmd_id`, cửa sổ 16 lệnh gần nhất | `[PROPOSED]` | 16 | 10.RL |
| D-11 | `duration_sec` tối đa | `[PROPOSED]` | 86 400 s (24 h), `0` = vĩnh viễn | 10.RV |
| D-12 | "Đổi Slave ID" chỉ đổi cấu hình phía host (địa chỉ firmware dùng để poll), **không** ghi lại địa chỉ vào thanh ghi cảm biến | `[DECISION-REQUIRED]` | Chỉ phía host | 8.2, R-15 |
| D-13 | Định nghĩa "used" và "xóa" cảm biến | `[DECISION-REQUIRED]` | `used = enabled == true`; "xóa" = `enabled=false`. (Nếu muốn tách, thêm cờ `configured` vào struct) | 8.2, 8.5 |
| D-14 | Sensor task đẩy **1 struct chu kỳ** (`sensor_cycle_t`, tối đa 5 mục) vào `sensor_data_queue` | `[PROPOSED]` | Áp dụng; cần đồng bộ với P4 | 5.7 |
| D-15 | `ts` = epoch ms UTC khi `BIT_TIME_VALID`, ngược lại bỏ trường `ts`; luôn có `uptime_ms`, `seq`, `boot_id` | `[PROPOSED]` | Áp dụng | 8.4 |
| D-16 | Ring buffer lưu **dạng nhị phân** (không lưu chuỗi JSON 256 B) | `[PROPOSED]` | Áp dụng (xem R-10) | 5.7 |
| D-17 | Quy tắc set/clear `SYS_ERR_MQTT_BROKER` | `[PROPOSED]` | Mục 7.4 | 7.4 |
| D-18 | Định nghĩa phép đo AC-02 (<5 s): từ sự kiện link-down đến CONNACK+SUBACK trên Wi-Fi? | `[DECISION-REQUIRED]` | Đo từ link-down đến SUBACK; có TLS thì ghi nhận riêng (R-06) | 13.6 |
| D-19 | `cmd_id[37]` (36 + NUL) | `[PROPOSED]` (sửa lỗi) | Áp dụng; đồng bộ `main_data_types.h` | 5.7 |
| D-20 | Thêm `origin` (MQTT/BLE/INTERNAL) vào lệnh và ACK | `[PROPOSED]` | Áp dụng | 5.7 |
| D-21 | Xác thực nguồn lệnh vượt ra ngoài ACL broker (ký HMAC, per-device secret) | `[DECISION-REQUIRED]` | Chưa có; chỉ dựa broker ACL + TLS (R-02) | 10.RZ |
| D-22 | Đổi `user_id` lúc runtime ⇒ restart MQTT toàn bộ, publish offline ở topic cũ | `[PROPOSED]` | Áp dụng | 9.9 |
| D-23 | Baudrate không hỗ trợ qua MQTT | `[PROPOSED]` | Áp dụng | 8.2 |
| D-24 | Ngưỡng `SYS_ERR_SENSOR_OUT_RANGE` chưa định nghĩa | `[DECISION-REQUIRED]` | `app_mqtt` chỉ mang `code_mask`, không tự set bit này | 8.4 |
| D-25 | Đồng bộ tên field JSON ↔ struct (`slave_id`↔`new_slave_id`…) | `[DECISION-REQUIRED]` | Dùng bảng ánh xạ 8.2.3; khuyến nghị đổi struct cho trùng JSON | 8.2 |
| D-26 | "Trạng thái an toàn" của tải = OFF cho **mọi** tải; thực tế có thể có tải (máy sục khí) mà OFF mới nguy hiểm | `[DECISION-REQUIRED]` | Tất cả OFF (như spec); ghi cảnh báo R-29 | 10.RF |

---

## 5. Kiến trúc và ranh giới trách nhiệm

### 5.1 Ai làm gì

| Việc | `app_mqtt` | Module khác |
| --- | --- | --- |
| Kết nối broker, subscribe, publish | **Sở hữu** | — |
| Quyết định mạng nào là default, failover | Không | `app_network` (P6) |
| Báo cho MQTT biết khi nào dừng/chạy | Nhận sự kiện FSM | `app_network` gọi callback |
| Parse + validate JSON lệnh/config | **Sở hữu** | — |
| Thực thi lệnh tải, timer tự ngắt, interlock | Không (chỉ đưa vào queue, phát ACK/event) | `app_control` (P5) |
| Ghi NVS, validate cấu hình sâu (trùng Slave ID…) | Không (đưa vào queue) | `app_nvm` / consumer của `config_cmd_queue` |
| Đọc cảm biến, tạo `sensor_cycle_t` | Không (tiêu thụ) | `app_modbus` (P4) |
| Error mask, LED, heap monitor | Đặt bit `SYS_ERR_MQTT_BROKER`; nhận heap/cờ lỗi để đưa vào status | `app_sysmon` (P3) |
| Chuyển state hệ thống (OPERATIONAL…) | Chỉ set/clear `BIT_MQTT_CONNECTED` | `main` / FSM |

**MUST NOT**: `app_mqtt` không chạm GPIO relay. Safety timer chỉ gọi `app_control_interlock_trip()`; toàn bộ relay GPIO writes thuộc `app_control`.

### 5.2 Task và ngữ cảnh thực thi

| Ngữ cảnh | Core / Priority / Stack | Việc |
| --- | --- | --- |
| Task nội bộ của esp-mqtt | Theo `CONFIG_MQTT_TASK_STACK_SIZE` | Chạy socket, gọi `event_handler` |
| `mqtt_client_task` (của ứng dụng) | Core 0, prio 5, stack 6144 | Xử lý hàng đợi RX, ACK, telemetry, status, feed TWDT |
| `net_mgmt_task` | Core 0, prio 6 | Gọi callback FSM → `app_mqtt_stop()` / `app_mqtt_start()` |
| Timer service task | Hệ thống | Callback backoff (**chỉ** đặt cờ/notify, không làm việc nặng) |

Ràng buộc:

- `event_handler` của esp-mqtt **MUST NOT** gọi `esp_mqtt_client_stop/destroy` (deadlock). **MUST NOT** parse JSON nặng hoặc publish blocking (xem RX-01).
- `mqtt_client_task` **MUST** gọi `esp_task_wdt_reset()` mỗi vòng, chu kỳ vòng ≤ 1 s kể cả khi đang offline/backoff (TWDT = 10 s).

### 5.3 Hàng đợi và quyền sở hữu

| Queue | Producer → Consumer | Phần tử | Độ sâu đề xuất | Khi đầy |
| --- | --- | --- | --- | --- |
| `rx_slot_queue` (nội bộ app_mqtt) | esp-mqtt handler → `mqtt_client_task` | Index slot RX tĩnh (4 slot × 1 KB) | 4 | Bỏ message, counter `rx_dropped`, không parse |
| `load_cmd_queue` | `mqtt_client_task` (và BLE) → `load_control_task` | `load_command_t` | 8 | ACK `busy` ngay |
| `config_cmd_queue` | `mqtt_client_task` → consumer cấu hình (**G11: phải chỉ định rõ**; đề xuất hàm `app_config_apply_task` trong `main` hoặc `app_nvm`) | `config_update_cmd_t` | 4 | ACK `busy` ngay |
| `load_ack_queue` | `load_control_task` → `mqtt_client_task` | `load_ack_t` | 16 | Bỏ ACK cũ nhất, counter `ack_dropped` |
| `sensor_data_queue` | `sensor_acquisition_task` → `mqtt_client_task` | `sensor_cycle_t` | 4 | Producer ghi đè mẫu cũ nhất (drop-oldest), không block sensor task |
| ack tổng quát (config, query) | consumer cấu hình → `app_mqtt_ack_submit()` | `mqtt_ack_t` | 16 (dùng chung hàng với `load_ack_queue` nếu có thể) | như trên |

Quy tắc sở hữu bộ nhớ: **MUST NOT** truyền con trỏ tới stack/heap giữa các task; mọi phần tử queue là struct giá trị (copy). Chuỗi trong struct luôn NUL-terminated.

### 5.4 Event bits dùng/định nghĩa (trong `sys_event_group`)

| Bit | Chủ sở hữu | Ý nghĩa |
| --- | --- | --- |
| `BIT_NET_ACTIVE_READY` | `app_network` | Default netif đã được chọn; DNS được cập nhật khi interface cung cấp DNS IPv4, nếu không thì giữ DNS toàn cục hiện tại |
| `BIT_SYS_NET_LOST` | `app_network` | Mất mạng toàn bộ |
| `BIT_TIME_VALID` | `app_mqtt` (SNTP) | Thời gian đã đồng bộ |
| `BIT_MQTT_CONNECTED` | `app_mqtt` (**thêm nếu chưa có**) | `ONLINE` (CONNACK OK + SUBACK OK cả 2 topic) |
| `BIT_SYS_INTERLOCK_TRIPPED` | `app_control` (tạm: `app_mqtt`) | Interlock đã ngắt tải, chưa có lệnh mới |
| `sys_error_mask & SYS_ERR_MQTT_BROKER` | `app_mqtt` | Theo 7.4 |

### 5.5 API công khai đề xuất (`components/app_mqtt/include/app_mqtt.h`)

```c
typedef struct {
    uint32_t connect_attempts, connect_ok, disconnects;
    uint32_t rx_total, rx_rejected, rx_dropped, rx_retained_ignored, rx_oversize, rx_dup;
    uint32_t tx_telemetry, tx_ack, tx_status, tx_fail;
    uint32_t telemetry_buffered, telemetry_dropped, ack_dropped;
    uint32_t last_error;            /* enum mqtt_last_error_t */
    uint32_t backoff_ms;            /* giá trị backoff hiện tại */
    uint32_t online_since_s;        /* 0 nếu offline */
} app_mqtt_stats_t;

esp_err_t app_mqtt_init(const app_config_t *cfg);   /* build topic, tạo client, KHÔNG kết nối */
esp_err_t app_mqtt_start(void);                      /* idempotent; chạy trên net_mgmt_task được */
esp_err_t app_mqtt_stop(uint32_t timeout_ms);        /* idempotent; bounded; không bao giờ block > timeout */
esp_err_t app_mqtt_shutdown_for_reset(void);         /* best-effort publish offline ≤ 300 ms rồi stop */
bool      app_mqtt_is_online(void);
esp_err_t app_mqtt_ack_submit(const mqtt_ack_t *a);  /* thread-safe, không block (timeout 0) */
esp_err_t app_mqtt_event_submit(const mqtt_event_t *e); /* app_control/app_sysmon/app_nvm gọi */
void      app_mqtt_get_stats(app_mqtt_stats_t *out);
const char *app_mqtt_get_broker_host(void);          /* broker identity; not a WAN probe */
uint16_t  app_mqtt_get_broker_port(void);
```

Ghi chú:

- `app_mqtt_init()` thất bại (ví dụ `CONFIG_APP_MQTT_BROKER_URI` rỗng, `user_id` không hợp lệ) **MUST** trả lỗi rõ ràng; `main` không được crash, chỉ log và để hệ thống chạy chế độ không MQTT (tải vẫn ở trạng thái an toàn).
- Mọi hàm submit **MUST NOT** block quá 0 ms; không bao giờ làm kẹt `load_control_task`.

### 5.6 Bố cục file (cập nhật cây file của `requirements.md` mục 12)

```
components/app_mqtt/
├── CMakeLists.txt
├── Kconfig
├── include/app_mqtt.h
├── app_mqtt.c                 # glue esp-mqtt: vòng đời, event handler, task, publish
├── app_mqtt_proto.[ch]        # THUẦN (không phụ thuộc ESP-IDF): build topic, validate, parse, serialize, dedupe, backoff tính toán
├── app_telemetry_buffer.[ch]  # ring buffer (đã có)
└── test/                      # unit test chạy được trên host (gcc + Unity + cJSON)
```

**MUST**: logic parse/validate/serialize/dedupe/backoff nằm trong `app_mqtt_proto` để test được trên máy host mà không cần board.

### 5.7 Cấu trúc dữ liệu đề xuất (cập nhật `main/main_data_types.h`, theo D-14/D-16/D-19/D-20)

```c
typedef enum { ORIGIN_INTERNAL = 0, ORIGIN_MQTT, ORIGIN_BLE } cmd_origin_t;

typedef struct {
    char         cmd_id[37];       /* UUID 36 ký tự + NUL  (D-19) */
    cmd_origin_t origin;           /* (D-20) */
    uint8_t      load_id;          /* 1..APP_LOAD_COUNT (1-based) */
    bool         target_state;
    uint32_t     duration_sec;     /* 0 = vĩnh viễn; chỉ hợp lệ khi target_state=true */
} load_command_t;

typedef enum { LOAD_ACK_OK = 0, LOAD_ACK_INVALID, LOAD_ACK_INTERLOCK, LOAD_ACK_INTERNAL } load_ack_result_t;

typedef struct {
    char              cmd_id[37];
    cmd_origin_t      origin;
    uint8_t           load_id;
    load_ack_result_t result;
    bool              state_after;     /* trạng thái thực sau khi thực thi (đọc lại từ app_control) */
    uint32_t          remaining_s;     /* 0 nếu không có timer */
} load_ack_t;

typedef struct {                       /* 1 phần tử của chu kỳ đọc */
    uint8_t     interface_type;        /* sensor_interface_type_t */
    uint8_t     interface_index;       /* 0-based */
    uint8_t     sensor_type;           /* sensor_type_t tại thời điểm lấy mẫu */
    uint8_t     valid;                 /* 0/1 */
    uint8_t     error;                 /* 0=none,1=timeout,2=crc,3=range,4=not_ready,5=disabled_mid_cycle,6=stopped,7=disabled,8=modbus_exception,9=protocol */
    float       v1, v2, v3;            /* SHT40: temp/humid; DO: mg/L/temp/saturation%; pH: pH/temp; analog: mA */
} sensor_sample_t;                     /* ~16 B */

typedef struct {
    uint32_t        seq;               /* tăng mỗi chu kỳ, kể cả khi bị drop */
    int64_t         ts_ms;             /* epoch ms nếu time valid, ngược lại 0 */
    uint32_t        uptime_ms;
    uint8_t         count;             /* <= APP_RS485_INTERFACE_COUNT + APP_ANALOG_4_20MA_INTERFACE_COUNT = 5 */
    sensor_sample_t s[5];
} sensor_cycle_t;                      /* ~100 B  → ring buffer 50 slot ≈ 5 KB */

typedef struct {
    char   cmd_id[37];                 /* rỗng nếu không trích được */
    uint8_t kind;                      /* ACK_LOAD, ACK_CONFIG, ACK_QUERY, ACK_REJECT */
    uint8_t result;                    /* 0=ok, 1=error */
    uint8_t code;                      /* enum mqtt_err_code_t (8.3.2) */
    bool    dup;
    union { /* chi tiết tùy kind */ struct { uint8_t load_id; bool state; uint32_t duration_sec, remaining_s; } load;
            struct { uint8_t itype, iindex; bool changed; } config; } u;
} mqtt_ack_t;
```

**Load-control extension (2026-10-08):** `load_control_cfg_t` is persisted per load in `app_config_t`; it includes weekly schedule and independent sensor ON/OFF conditions. `load_command_t` carries an explicit command kind and paired minute fields for timed cycles; `config_update_cmd_t` adds `CFG_CMD_UPDATE_LOAD_CONTROL`. Exact JSON names, ranges, sensor IDs, operators, ACK and snapshot fields are normative in [`json_payoad.md`](json_payoad.md). NVS uses schema v3 and migrates schema v1/v2 with sensor conditions defaulting to disabled.

**Lưu ý đồng bộ**: `sensor_cycle_t` thay `sensor_data_t` scalar trên đường `sensor_data_queue → mqtt`. Giữ `sensor_data_t` chỉ khi module khác còn dùng; ghi rõ trong `pipline.md`.

---

## 6. Danh tính, kết nối và bảo mật kênh

### 6.1 Định danh

| Thành phần | Quy tắc |
| --- | --- |
| `user_id` | Từ NVM. 1–36 ký tự ASCII hiển thị (0x21–0x7E), đủ chứa UUID Supabase; **cấm** `/`, `+`, `#`. Kiểm tra lại khi `app_mqtt_init()` (không tin NVM). Rỗng/không hợp lệ ⇒ **không start MQTT**. |
| `device_id` | `esp_read_mac(mac, ESP_MAC_WIFI_STA)` (hoạt động cả khi radio Wi-Fi chưa chạy hoặc `only_use_ethernet=true`), định dạng 12 ký tự hex **chữ thường**, cache khi init. Cũng được trả cho app qua BLE `prov-config` và `prov-status` để dùng làm khóa thiết bị trong database. `[PROVISIONAL, D-04]` |
| `client_id` | = `device_id`. |
| Topic | Build 1 lần khi `init` bằng `snprintf` vào buffer 80 B; **MUST** kiểm tra giá trị trả về < kích thước (không bị cắt cụt). Độ dài tối đa = 3 + 31 + 9 + 12 + 11 = 66 byte. |

Danh sách topic (D-02):

| Hướng | Topic | QoS | Retain | Ghi chú |
| --- | --- | --- | --- | --- |
| Device → Cloud | `v1/{user_id}/devices/{device_id}/telemetry` | 0 | không | |
| Cloud → Device | `v1/{user_id}/devices/{device_id}/commands` | 1 | không (bỏ qua nếu retained) | |
| Device → Cloud | `v1/{user_id}/devices/{device_id}/ack` | 1 | không | |
| Cloud → Device | `v1/{user_id}/devices/{device_id}/config/set` | 1 | không (bỏ qua nếu retained) | |
| Device → Cloud | `v1/{user_id}/devices/{device_id}/status` | 1 | **chỉ `presence`** retained | snapshot/event không retained |

### 6.2 Tham số `esp_mqtt_client_config_t` bắt buộc

| Tham số | Giá trị | Lý do |
| --- | --- | --- |
| `network.disable_auto_reconnect` | `true` | Tự quản backoff (khớp code) |
| `session.keepalive` | 30 s `[PROPOSED]` | Broker phát hiện chết sau ~45 s |
| `session.disable_clean_session` | `false` (tức `clean_session=true`) | Tránh broker xếp hàng lệnh QoS 1 cũ rồi phát lại sau khi nối lại (R-01) |
| `session.last_will` | topic `status`, QoS 1, retain, payload `presence offline` | 8.5.1 |
| `network.timeout_ms` | ≤ 4000 ms | Một lệnh publish/stop bị kẹt không được vượt TWDT 10 s (R-04) |
| `network.reconnect_timeout_ms` | không dùng (đã tắt auto reconnect) | |
| `buffer.size` / `buffer.out_size` | RX ≥ 1024, TX ≥ 5120 để snapshot cấu hình đủ 4 tải không bị cắt |
| `credentials.client_id` | `device_id` | 6.1 |
| `credentials.username/authentication.password` | Từ Kconfig `[PROVISIONAL]` | D-05 |
| `broker.verification` | CA bundle hoặc `certificate` ghim, **không** `skip_cert_common_name_check` ở build production | 6.5 |
| `task.stack_size` | ≥ 6144 (đo watermark bằng test) | cJSON + TLS |

### 6.3 Điều kiện cho phép start

MQTT **MUST** chỉ `start` khi đồng thời:

1. `user_id` hợp lệ.
2. `broker URI` không rỗng và parse được host/port.
3. `BIT_NET_ACTIVE_READY` đã set (default netif đã chọn thành công; DNS được cập nhật nếu interface cung cấp DNS IPv4).
4. Nếu dùng TLS: `BIT_TIME_VALID` (xem 6.5).
5. Không đang `shutdown_for_reset`.

Thiếu điều kiện 1 hoặc 2 ⇒ trạng thái `STOPPED` + log lỗi cấu hình + `last_error=MQTT_ERR_NOT_CONFIGURED`; **không** retry (không có ích) cho đến khi cấu hình thay đổi.

### 6.4 Nguồn broker `[CONFIRMED, D-05; development endpoint only]`

Nguồn cấu hình: `CONFIG_APP_MQTT_BROKER_URI`, `CONFIG_APP_MQTT_USERNAME`, `CONFIG_APP_MQTT_PASSWORD`. Broker mặc định cho phát triển là `mqtt://broker.emqx.io:1883`, không xác thực; plaintext chỉ được phép khi `CONFIG_APP_MQTT_ALLOW_PLAINTEXT=y`. Đây là broker công cộng, không dùng cho dữ liệu riêng tư, điều khiển thực hoặc production.

- Kconfig phải hỗ trợ `mqtts://host:8883` và `mqtt://host:1883`.
- Username/password **MUST NOT** xuất hiện trong log ở mọi mức.
- Không đưa broker URI/credential vào `prov-config` hay NVS.
- Production bắt buộc thay broker công cộng bằng broker TLS riêng và credential riêng cho từng thiết bị (hoặc mTLS), nạp lúc sản xuất; bảo vệ dữ liệu bằng flash encryption. Ghi nhận ở R-14.

### 6.5 TLS `[DECISION-REQUIRED, D-06]`

1. Production: bắt buộc `mqtts://` + xác thực chuỗi chứng chỉ server.
2. Xác thực chứng chỉ **phụ thuộc đồng hồ**. Vì vậy với TLS: sau khi có IP, `app_mqtt` đợi `BIT_TIME_VALID` (SNTP) trước khi kết nối; trong lúc đợi `STATE=WAIT_TIME`, retry SNTP, **không** nối bằng chế độ không kiểm tra chứng chỉ. Nếu đồng hồ không đồng bộ sau 60 s ⇒ giữ `SYS_ERR_MQTT_BROKER`, log `time_not_synced`, tiếp tục thử.
3. Mọi lỗi TLS (cert hết hạn, sai CN, CA lạ) phân loại vào `last_error` riêng và dùng backoff **chậm** (60 s) để không đốt CPU/năng lượng.
4. Plain MQTT chỉ khi `CONFIG_APP_MQTT_ALLOW_PLAINTEXT=y` (mặc định `n`); khi bật phải in cảnh báo ở boot.
5. Thời gian TLS handshake trên ESP32-S3 (vài giây với RSA 2048) ảnh hưởng AC-02 (<5 s) — xem R-06.

Đồng hồ hệ thống dùng C time API (`time()`/`gmtime_r()`). Khi network có Internet, SNTP đồng bộ ban đầu và cập nhật định kỳ mỗi giờ (`CONFIG_LWIP_SNTP_UPDATE_DELAY=3600000`); giữa các lần hỏi NTP, system timekeeping/RTC duy trì thời gian để dùng cho TLS và lịch UTC, không cần truy vấn mạng liên tục.

---

## 7. Máy trạng thái MQTT

### 7.1 Trạng thái

| State | Ý nghĩa | Ghi chú |
| --- | --- | --- |
| `MQTT_STOPPED` | Chưa start hoặc đã dừng (mất mạng, đang failover, shutdown) | Không có socket |
| `MQTT_WAIT_TIME` | Có mạng, chờ SNTP (chỉ khi TLS) | |
| `MQTT_CONNECTING` | Đã gọi connect, chờ CONNACK | Timeout 10 s (cấu hình) |
| `MQTT_SUBSCRIBING` | CONNACK OK, chờ SUBACK cho cả 2 topic | Timeout 5 s |
| `MQTT_ONLINE` | Đủ điều kiện nhận lệnh/gửi dữ liệu | Set `BIT_MQTT_CONNECTED` |
| `MQTT_BACKOFF` | Chờ thử lại, timer jitter | |

### 7.2 Bảng chuyển trạng thái

| Từ | Sự kiện | Hành động | Đến |
| --- | --- | --- | --- |
| `STOPPED` | `start()` + đủ điều kiện (6.3) | — | `WAIT_TIME` (TLS & chưa có time) hoặc `CONNECTING` |
| `WAIT_TIME` | `BIT_TIME_VALID` | connect | `CONNECTING` |
| `CONNECTING` | CONNACK rc=0 | subscribe 2 topic | `SUBSCRIBING` |
| `CONNECTING` | CONNACK từ chối (auth) / lỗi TLS / timeout / lỗi socket | tăng lỗi, set error (7.4), đặt backoff | `BACKOFF` |
| `SUBSCRIBING` | SUBACK cả 2 thành công | set `BIT_MQTT_CONNECTED`, clear error, publish presence online, publish snapshot, bắt đầu xả buffer | `ONLINE` |
| `SUBSCRIBING` | SUBACK thất bại (0x80) hoặc timeout | disconnect | `BACKOFF` |
| `ONLINE` | `DISCONNECTED` / lỗi socket | clear `BIT_MQTT_CONNECTED`, bắt đầu đếm "mất kênh điều khiển" (RF), đặt error (7.4), đặt backoff (reset nếu đã online ổn định ≥ 30 s) | `BACKOFF` |
| `BACKOFF` | Timer hết | connect (kiểm tra lại điều kiện 6.3) | `CONNECTING` / `WAIT_TIME` |
| bất kỳ (≠`STOPPED`) | FSM `SWITCH_BEGIN` | `stop(timeout)`; **không** set `SYS_ERR_MQTT_BROKER` (dừng có kế hoạch); hủy timer backoff | `STOPPED` |
| `STOPPED` | FSM `SWITCH_DONE` (default netif + DNS đã cập nhật) | **reset backoff về 0**, connect ngay (không chờ) | `CONNECTING` |
| bất kỳ | FSM `LOST` (mất cả ETH + Wi-Fi) | `stop`, set `SYS_ERR_NET_LOST` do `app_network` quản; MQTT không set `SYS_ERR_MQTT_BROKER` | `STOPPED` |
| bất kỳ | `shutdown_for_reset()` | 9.10 | `STOPPED` (cuối cùng) |
| bất kỳ | `user_id` đổi (D-22) | `shutdown` + re-init topic + start lại | … |

### 7.3 Ma trận sự kiện × hành vi

| Sự kiện bên ngoài | Hành vi của `app_mqtt` |
| --- | --- |
| Rút cáp Ethernet, Wi-Fi sẵn sàng | `SWITCH_BEGIN` → stop; `SWITCH_DONE` → connect ngay (backoff=0) |
| Mất cả 2 mạng | `LOST` → stop; telemetry đưa vào ring buffer; đếm interlock chạy |
| Mạng ổn, broker tắt | `DISCONNECTED` → `BACKOFF`; `SYS_ERR_MQTT_BROKER` set theo 7.4; mạng **không** bị đổi (Rule D) |
| Runtime provisioning (`STATE_BLE_PROV_RUNTIME`) đang chạy | MQTT **tiếp tục chạy** bình thường; tải/timeout không bị ảnh hưởng |
| Factory reset (giữ ≥ 5 s, nhả, giữ lại 5 s) | `APP_NET_EVENT_SHUTDOWN` → `shutdown_for_reset()` bounded; không cản `esp_restart()` sau 500 ms |
| `BIT_TIME_VALID` đổi 0→1 lúc đang online | Cho phép `ts` trong telemetry từ chu kỳ sau; không reconnect |
| Heap < 20 KB | Phát `event low_heap`; không ngừng MQTT |
| NVS lỗi khi ghi config | Consumer báo ACK `storage_error` qua `app_mqtt_ack_submit()`; `SYS_ERR_NVM_FAIL` do consumer set |
| `config_cmd_queue` consumer chưa chạy | ACK `busy`/`internal_error`, **không** để lệnh treo vô hạn |

### 7.4 Quy tắc `SYS_ERR_MQTT_BROKER` `[PROPOSED, D-17]`

- **Set** khi: mạng đang sẵn sàng (`BIT_NET_ACTIVE_READY` và không `NET_LOST`) **và** MQTT không `ONLINE` liên tục **≥ 10 s** (debounce, tránh nháy LED trong lúc failover bình thường); hoặc khi có lỗi auth/TLS (set ngay).
- **Clear** khi vào `ONLINE`.
- **Không** set khi `STOPPED` do `SWITCH_BEGIN`/`LOST`/shutdown (nguyên nhân là mạng, đã có `SYS_ERR_NET_LOST`).
- LED_ERROR theo `app_sysmon`: `NET_LOST`/`MQTT_BROKER` ⇒ nháy 1 Hz.

---

## 8. Hợp đồng thông điệp (Message Contracts)

> Spec gốc chỉ nói "JSON chuẩn hóa" mà không định nghĩa schema MQTT. Mục này là schema **chuẩn tắc** của tài liệu này `[PROPOSED]`, dùng cùng tên field với endpoint BLE (`load-ctrl`, `sensor-config`, `sys-status`) trong `requirements.md` mục 7 để app dùng một bộ khái niệm. Agent phải đối chiếu với parser hiện có trong `app_mqtt.c`; nếu tên field của code hiện tại khác, **sửa code theo mục này** (và ghi vào `pipline.md`).

### 8.1 Quy ước chung

| Mục | Quy tắc |
| --- | --- |
| Mã hóa | UTF-8, JSON object, **phẳng** (cấm lồng object/array trong thông điệp **nhận**; riêng thông điệp **gửi** telemetry/snapshot có mảng) |
| Phiên bản | Field `"v": 1` (số nguyên). Thiếu `v` khi nhận = coi như 1. `v` khác 1 ⇒ từ chối `unsupported_version` |
| Số | Số nguyên là số nguyên JSON (không `1.0`); số thực phải hữu hạn (không NaN/Inf) |
| Định danh tương quan | `cmd_id`: chuỗi 1–36 ký tự `[A-Za-z0-9_-]` (UUID chuẩn 36 ký tự hợp lệ) |
| Thời gian | `ts`: epoch **mili giây** UTC (số nguyên). Không có `ts` nghĩa là thiết bị chưa đồng bộ giờ |
| Kích thước tối đa nhận | `commands` ≤ 512 B; `config/set` ≤ 768 B |
| Kích thước tối đa gửi | `telemetry` ≤ 1024 B; `ack` ≤ 512 B; `status` ≤ 5120 B. **Không bao giờ gửi JSON bị cắt cụt**: nếu serialize vượt, bỏ message + counter + log |
| Trường lạ | Bỏ qua (tương thích tiến), **trừ** trường bị cấm (8.2.4) |
| Chuỗi tên | 1–31 byte UTF-8 hợp lệ, không ký tự điều khiển (<0x20, 0x7F), không khoảng trắng đầu/cuối; khi **xuất ra JSON** phải escape đúng (`"`, `\`, điều khiển) |

### 8.2 Thông điệp nhận

#### 8.2.1 Topic `commands` — điều khiển tải

**a) `SET_STATE`**

```json
{"v":1,"cmd_id":"3f2b8c1e-6d7a-4b1f-9a52-0c1d2e3f4a5b","action":"SET_STATE",
 "load_id":1,"state":true,"duration_sec":60,"ts":1790000000000}
```

| Field | Bắt buộc | Kiểu / miền | Ghi chú |
| --- | --- | --- | --- |
| `cmd_id` | có | string 1–36 | |
| `action` | có | `"SET_STATE"` | |
| `load_id` | có | integer 1..4 (1-based) | Khác `interface_index` (0-based) — **không nhầm** |
| `state` | có | boolean | Không chấp nhận `0/1`, `"true"` |
| `duration_sec` | không | integer 0..86400 (D-11) | Mặc định 0 = vĩnh viễn. **Chỉ hợp lệ khi `state=true`**; `state=false` kèm `duration_sec>0` ⇒ `invalid_value` |
| `duration_min` | không | integer 0..86400 | Field ưu tiên mới cho auto-off tính bằng phút; không gửi cùng `duration_sec`; chỉ hợp lệ khi `state=true` |
| `ts` | không | integer | Dùng cho kiểm tra tuổi lệnh (RL-06) |
| `new_name` | cấm | — | Đổi tên đi qua `config/set` (một message = một thao tác nguyên tử) ⇒ `invalid_fields` |

**b) `SET_LOAD_CYCLE`** — một command chứa cả cặp thời gian, dùng một lần (không phải lịch):

```json
{"v":1,"cmd_id":"cycle-01","action":"SET_LOAD_CYCLE","load_id":1,"mode":"ON_THEN_OFF","on_delay_min":5,"duration":60}
```

`mode=ON_THEN_OFF` dùng `on_delay_min` + `duration`; `mode=OFF_THEN_ON` dùng `off_delay_min` + `duration`. Đơn vị phút; cả delay và duration trong 0..1440. `duration=0` nghĩa là không có lần đổi trạng thái thứ hai. Field delay của mode không chọn bị bỏ qua. Lệnh mới thay cycle đang chờ của cùng tải. Chi tiết JSON chuẩn và ví dụ chiều ngược nằm trong `json_payoad.md`.

**c) `SET_ALL_OFF`** `[PROPOSED]` — dừng khẩn cấp

```json
{"v":1,"cmd_id":"...","action":"SET_ALL_OFF"}
```
Tắt cả 4 tải, hủy mọi timer tự ngắt. **Không bao giờ bị từ chối vì `expired`** (RL-10).

**d) `GET_STATUS`** — yêu cầu snapshot

```json
{"v":1,"cmd_id":"...","action":"GET_STATUS"}
```
Phát snapshot lên `status` (8.5.2) và ACK `kind=query`.

**e) `SET_TELEMETRY_INTERVAL`** — cài chu kỳ gửi telemetry định kỳ, từ 5 đến 600 giây:

```json
{"v":1,"cmd_id":"...","type":"SET_TELEMETRY_INTERVAL","interval_s":30}
```

Firmware xác thực số nguyên trong khoảng 5–600, lưu vào NVM, áp dụng ngay và trả snapshot mới có `telemetry_interval_s`.

**f) `EMERGENCY_STOP` / `EMERGENCY_RELEASE`** — latch E-STOP (chi tiết payload/ACK ở `json_payoad.md`):

```json
{"v":1,"cmd_id":"estop-01","action":"EMERGENCY_STOP"}
{"v":1,"cmd_id":"release-01","action":"EMERGENCY_RELEASE","confirm":true}
```

Hai action gọi API đồng bộ của `app_control`, không đi qua `load_cmd_queue`; bỏ qua timestamp cũ và queue-full. `EMERGENCY_RELEASE` thiếu `confirm:true` ⇒ `invalid_fields`; mọi lệnh bật khi đang latch ⇒ `emergency_active`.

Action khác ⇒ `unsupported_action`.

#### 8.2.2 Topic `config/set` — cấu hình

**a) `type="sensor"`** — thay thế toàn bộ một slot (full-replace, không patch)

```json
{"v":1,"cmd_id":"...","type":"sensor",
 "interface_type":"rs485","interface_index":2,"sensor_type":"ph",
 "slave_id":3,"name":"pH_Tank_A1","enabled":true}
```

| Field | Bắt buộc | Miền |
| --- | --- | --- |
| `interface_type` | có | `"rs485"` \| `"analog_4_20ma"` |
| `interface_index` | có | rs485: 0..3; analog_4_20ma: 0 |
| `sensor_type` | có | rs485: `"sht40"`,`"do"`,`"ph"`; analog_4_20ma: `"analog_4_20ma"`. Ghép sai ⇒ `invalid_value` |
| `slave_id` | rs485: có; analog: bỏ qua | integer 1..247, **không trùng** với slot rs485 khác đang `enabled` (⇒ `conflict`) |
| `name` | có | theo 8.1 |
| `enabled` | có | boolean |

Thiếu bất kỳ field bắt buộc ⇒ `invalid_fields`. App muốn sửa 1 field phải đọc snapshot rồi gửi lại **đủ** field (vì `config_update_cmd_t` luôn mang đủ giá trị, không có cờ "có mặt").

Hành vi: "thêm cảm biến" = gửi cho slot chưa dùng với `enabled=true`; "xóa" = `enabled=false` (D-13). Slave ID chỉ đổi cấu hình phía host (D-12). Baudrate không có (D-23).

**b) `type="load_name"`**

```json
{"v":1,"cmd_id":"...","type":"load_name","load_id":1,"name":"Pump_Water_A"}
```

**c) `type="load_control"`** — full-replace quyền điều khiển, lịch tuần và điều kiện cảm biến (field bắt buộc, ID/operator và miền được định nghĩa tại `json_payoad.md`):

```json
{"v":1,"cmd_id":"policy-01","type":"load_control","load_id":1,"enabled":true,"schedule_enabled":false,"days_mask":0,"on_time_utc":"06:00","off_time_utc":"18:00","on_condition_enabled":true,"on_sensor_id":"sensor_001","on_operator":"lt","on_threshold":10,"off_condition_enabled":true,"off_sensor_id":"sensor_001","off_operator":"gte","off_threshold":20}
```

Không được bật lịch tuần đồng thời với một trong hai rule cảm biến. `enabled=false` tắt tải ngay, hủy timer/cycle và vô hiệu hóa lịch cùng hai rule. `sensor_001`…`sensor_004` ánh xạ RS485 index 0…3, `sensor_005` ánh xạ analog index 0. Điều kiện được đánh giá cục bộ trên sample mới, so sánh giá trị chính `v1`, và bỏ qua trong lúc có lệnh tay đang chạy. Sample thiếu/invalid của sensor được tham chiếu đưa tải về OFF; OFF thắng nếu cả hai rule cùng khớp. E-STOP và Interlock tiếp tục có quyền ưu tiên an toàn. Lịch chỉ chạy khi `BIT_TIME_VALID`; mốc schedule đụng lúc cycle đang chạy bị bỏ qua. NVS schema v3 migrate schema v1/v2 với rule cảm biến tắt mặc định.

**d) `type="network"`** (hoặc có mặt bất kỳ trong `ssid`, `password`, `user_id`, `mqtt_url`, `mqtt_port`, `broker`, `only_use_ethernet`) ⇒ **`forbidden`** (D-08). Lý do: đổi Wi-Fi từ xa có thể làm mất thiết bị; đổi `user_id` làm đổi topic.

#### 8.2.3 Bảng ánh xạ JSON ↔ struct (đến khi D-25 được chốt)

| JSON | Struct |
| --- | --- |
| `load_id` | `load_command_t.load_id`, `config_update_cmd_t.payload.load_info.load_id` |
| `state` | `load_command_t.target_state` |
| `duration_sec` | `load_command_t.duration_sec` |
| `interface_type` | `sensor_info.interface_type` (`"rs485"`→`SENSOR_INTERFACE_RS485`, `"analog_4_20ma"`→`SENSOR_INTERFACE_ANALOG_4_20MA`) |
| `interface_index` | `sensor_info.interface_index` |
| `sensor_type` | `sensor_info.sensor_type` (`"sht40"`→`SENSOR_SHT40`, `"do"`→`SENSOR_DO`, `"ph"`→`SENSOR_PH`, `"analog_4_20ma"`→`SENSOR_ANALOG_4_20MA`) |
| `slave_id` | `sensor_info.new_slave_id` |
| `name` | `sensor_info.new_name` / `load_info.new_name` |
| `enabled` | `sensor_info.enabled` |

`config_update_cmd_t` **MUST** có thêm `cmd_id[37]` và `origin` để consumer trả kết quả đúng cho ACK.

#### 8.2.4 Trường bị cấm (⇒ `forbidden` hoặc `invalid_fields`)

| Topic | Trường cấm | Mã lỗi |
| --- | --- | --- |
| `commands` | `new_name` | `invalid_fields` |
| `config/set` | `ssid`, `password`, `user_id`, `mqtt_url`, `mqtt_port`, `broker`, `only_use_ethernet`, `type:"network"` | `forbidden` |

### 8.3 Thông điệp `ack` (Device → Cloud, QoS 1)

#### 8.3.1 Cấu trúc

```json
{"v":1,"cmd_id":"3f2b...","kind":"load","result":"ok","code":"ok",
 "load":{"load_id":1,"state":true,"duration_sec":60,"remaining_s":60},
 "dup":false,"ts":1790000000450}
```

```json
{"v":1,"cmd_id":"9a1c...","kind":"config","result":"ok","code":"ok",
 "config":{"interface_type":"rs485","interface_index":2,"changed":true},"dup":false}
```

```json
{"v":1,"cmd_id":"77aa...","kind":"load","result":"error","code":"invalid_value",
 "reason":"duration_sec out of range","dup":false}
```

```json
{"v":1,"cmd_id":null,"kind":"reject","result":"error","code":"invalid_json","dup":false}
```

Quy tắc:

- `kind`: `load` | `config` | `query` | `reject` | `emergency`.
- E-STOP dùng `kind=emergency`, payload `emergency:{active,changed,loads_off}`; `emergency_active` là mã lỗi khi lệnh bật bị latch chặn.
- `load.state` là **trạng thái thực sau khi thực thi** (đọc lại từ `app_control`), không phải trạng thái yêu cầu.
- `reason` ngắn (≤ 48 ký tự), chuỗi hằng của firmware, **không** lặp lại nguyên văn dữ liệu người dùng.
- `dup:true` khi trả lại kết quả đã lưu cho `cmd_id` trùng (RL-05); `ts` có mặt khi thời gian hợp lệ.
- `cmd_id: null` khi không trích được từ message hỏng.

#### 8.3.2 Bảng mã kết quả

| `code` | Khi nào | App nên làm gì |
| --- | --- | --- |
| `ok` | Thành công (kể cả lệnh idempotent: tắt tải đã tắt) | — |
| `invalid_json` | Không phải JSON hợp lệ / không phải object / lồng quá phẳng | Sửa message |
| `invalid_fields` | Thiếu field bắt buộc, sai kiểu, field bị cấm trong `commands` | Sửa message |
| `invalid_value` | Ngoài miền (load_id, duration_sec, slave_id, sensor_type không hợp lệ cho interface…) | Sửa message |
| `unsupported_action` | `action`/`type` không biết | — |
| `unsupported_version` | `v` ≠ 1 | Nâng cấp app/firmware |
| `forbidden` | Thao tác bị cấm (config mạng) | Dùng BLE provisioning |
| `conflict` | Slave ID trùng slot khác đang bật | Chọn ID khác |
| `expired` | Lệnh quá cũ (RL-06) | Gửi lại lệnh mới |
| `busy` | Queue đầy / đang áp config trước / rate limit | Thử lại sau ≥ 1 s **với `cmd_id` mới** |
| `payload_too_large` | Vượt giới hạn kích thước | — |
| `shutting_down` | Thiết bị đang reset/restart | — |
| `storage_error` | Ghi NVS thất bại | Báo lỗi; thử lại |
| `interlock_active` | (dự phòng) app_control từ chối vì interlock | Chờ `interlock_cleared` |
| `emergency_active` | E-STOP đang chốt | Yêu cầu người dùng release E-STOP |
| `internal_error` | Lỗi nội bộ (hết bộ nhớ, consumer không phản hồi trong 5 s) | Thử lại |

Tên mã lỗi dùng chung với BLE (`invalid_json|invalid_fields|invalid_value|storage_error`) để app xử lý thống nhất.

### 8.4 Thông điệp `telemetry` (Device → Cloud, QoS 0, không retain)

Telemetry trực tiếp được gửi mỗi **5 giây**, sử dụng chu kỳ cảm biến mới nhất và chứa mọi interface đang `enabled`. Chu kỳ đọc cảm biến và cập nhật điều khiển tải không thay đổi. Khi mất mạng, buffer cũng ghi một mẫu mỗi 5 giây; replay dữ liệu đã buffer giữ nguyên cơ chế hiện tại.

```json
{"v":1,"seq":10452,"boot_id":"a1b2c3d4","ts":1790000000123,"uptime_ms":86412345,
 "buffered":false,"net_interface":"ETH",
 "sensors":[
  {"interface_type":"rs485","interface_index":0,"sensor_type":"sht40","name":"Temp_Humid_Room","valid":true,"temp":29.1,"humid":68.4},
  {"interface_type":"rs485","interface_index":1,"sensor_type":"do","name":"DO_Tank_1","valid":true,"do_mg_l":6.82,"temperature_c":27.5,"do_saturation_pct":96.2},
  {"interface_type":"rs485","interface_index":2,"sensor_type":"ph","name":"pH_Tank_A1","valid":true,"ph_val":7.2,"temperature_c":27.4}
 ],
 "errors":{"code_mask":1}}
```

| Field | Quy tắc |
| --- | --- |
| `seq` | uint32, tăng 1 mỗi mẫu telemetry được tạo (mỗi 5 giây), độc lập với sequence chu kỳ đọc cảm biến. Giữ nguyên khi buffer/replay; mẫu bị drop có thể tạo khoảng trống sequence. |
| `boot_id` | 8 hex ngẫu nhiên sinh một lần mỗi lần boot (`esp_random`) → app biết thiết bị reboot, reset `seq` |
| `ts` | Có khi `BIT_TIME_VALID` **tại thời điểm lấy mẫu**; ngược lại **bỏ trường** (D-15) |
| `uptime_ms` | Luôn có |
| `buffered` | `true` nếu là mẫu xả lại từ ring buffer |
| `net_interface` | `"ETH"` \| `"WIFI"` \| `"NONE"` tại thời điểm **gửi** |
| `sensors[]` | Chỉ các interface `enabled`. Khóa định danh của app **MUST** là `(interface_type, interface_index)`, **không** dùng `name` (tên có thể đổi) |
| Đại lượng | `sht40`: `temp` (°C, 1 chữ số thập phân), `humid` (%RH, 1); `do`: `do_mg_l` (mg/L, 2), `temperature_c` (°C, 1), `do_saturation_pct` (%, 1); `ph`: `ph_val` (2), `temperature_c` (°C, 1); `analog_4_20ma`: `current_ma` (mA, 2) + (chờ P0) `value`/`unit` |
| `valid:false` | **Bỏ** các field đại lượng, thêm `error`: `timeout` \| `crc` \| `out_of_range` \| `not_ready` \| `disabled_mid_cycle` \| `disabled` \| `modbus_exception` \| `protocol` \| `offline` \| `stopped` |
| `errors.code_mask` | `sys_error_mask` hiện tại. `app_modbus` cập nhật `SYS_ERR_MODBUS_TIMEOUT` cho timeout/frame/CRC và `SYS_ERR_SENSOR_OUT_RANGE` cho giá trị ngoài dải. |
| `name` khi xả buffer | Lấy **tên hiện tại** tại thời điểm serialize (không lưu tên trong ring buffer) |

Một sensor lỗi chỉ làm **mục đó** invalid; các sensor khác vẫn gửi (AC-03).

### 8.5 Thông điệp `status` (Device → Cloud, QoS 1)

Topic `status` mang 3 loại message, phân biệt bằng `type`. **Chỉ `presence` được retained**, vì MQTT chỉ giữ 1 message retained cho mỗi topic; nếu snapshot/event cũng retained thì sẽ ghi đè presence.

#### 8.5.1 `presence` (retained)

```json
{"v":1,"type":"presence","state":"online","boot_id":"a1b2c3d4","fw":"1.0.0","ts":1790000000000}
```

- Gửi `online` ngay khi vào `ONLINE` (sau SUBACK). Retained, QoS 1.
- **LWT** (đặt lúc connect, payload cố định): `{"v":1,"type":"presence","state":"offline","reason":"lwt","boot_id":"a1b2c3d4"}`, retained, QoS 1.
- Shutdown có kế hoạch: gửi `{"state":"offline","reason":"factory_reset"|"user_id_changed"|"shutdown"}` retained, best-effort.
- Hành vi LWT khi broker xử lý "client takeover" (cùng `client_id`) **tùy broker** ⇒ phải kiểm thử (T-PRES-05). App **MUST** dùng `boot_id` + `ts` để không bị "offline giả" làm sai trạng thái.

#### 8.5.2 `snapshot` (không retained) — tương đương `sys-status`

Gửi khi: vừa `ONLINE` (ngay sau presence), định kỳ 60 s (Kconfig), khi nhận `GET_STATUS`.

```json
{"v":1,"type":"snapshot","boot_id":"a1b2c3d4","ts":1790000000200,"uptime_ms":86412345,
 "capabilities":{
   "rs485":{"supported":true,"count":4},"analog_4_20ma":{"supported":true,"runtime_available":false,"count":1},
   "digital_inputs":{"supported":true,"runtime_available":false,"count":4},"digital_outputs":{"supported":true,"count":4},
   "loads":{"supported":true,"count":4}},
 "runtime_interfaces":{"rs485_used":3,"analog_4_20ma_used":0,"loads_used":2},
 "net_interface":"ETH","ssid":"","ip_address":"192.168.1.30",
 "sensors":[
   {"interface_type":"rs485","interface_index":0,"sensor_type":"sht40","name":"Temp_Humid_Room",
    "enabled":true,"slave_id":1,"valid":true,"temp":29.1,"humid":68.4}],
 "digital_inputs":[false,false,false,false],
 "digital_outputs":[true,false,false,false],
 "loads":[{"load_id":1,"name":"Pump_Water_A","state":true,"remaining_s":42,
           "cycle_mode":"ON_THEN_OFF","cycle_next":"off","cycle_delay_min":5,"cycle_duration_min":60},
          {"load_id":2,"name":"Load_2","state":false,"remaining_s":0}],
 "interlock":{"tripped":false},
 "emergency":{"active":false},
 "errors":{"code_mask":1,"messages":["SYS_ERR_MODBUS_TIMEOUT on pH Sensor"]},
 "heap":{"free":182340,"min_free":150112},
 "mqtt":{"reconnects":3,"rx_rejected":0,"tx_fail":0,"telemetry_dropped":0}}
```

Quy tắc:

- `capabilities` và `runtime_interfaces` **MUST** có (yêu cầu của `requirements.md` mục 4.1). `count` = capacity firmware, `used` = theo D-13.
- `sensors[]` ở snapshot mang **cấu hình đầy đủ** (`enabled`, `slave_id`) để app làm read-modify-write.
- Mỗi sensor có `sensor_id` ổn định (`sensor_001`…`sensor_005`); mỗi load có đủ field cấu hình ON/OFF condition để app thực hiện full-replace.
- `loads[]` luôn đủ 4 phần tử (khác ví dụ BLE chỉ liệt kê load đã dùng) — để app render đúng theo `capabilities`.
- `loads[]` mang `cycle_mode` (`none|ON_THEN_OFF|OFF_THEN_ON`), `cycle_next` (`on|off|none`), `cycle_delay_min`, `cycle_duration_min`; top-level `emergency.active` biểu diễn E-STOP latch.
- `digital_inputs`: hành vi DI chưa được chốt (mục 13 `requirements.md`); gửi mảng bool đọc được, không suy luận.
- **MUST NOT** chứa: mật khẩu Wi-Fi, SSID, username/password broker, PoP.
- `errors.messages[]` tối đa 8 chuỗi hằng.
- Khi E-STOP latch, các sample cảm biến giữ identity nhưng `valid=false,error="stopped"`.
- ≤ 5120 B; MQTT transport TX buffer mặc định 5120 B.

#### 8.5.3 `event` (không retained, QoS 1) — rate-limit theo từng `event`

| `event` | Khi nào | Field thêm |
| --- | --- | --- |
| `load_changed` | Tải đổi trạng thái **bất kể nguyên nhân** | `load_id`, `state`, `source`: `mqtt`\|`timer`\|`schedule`\|`cycle`\|`sensor`\|`disable`\|`interlock`\|`estop`\|`button`\|`boot` |
| `load_auto_off` | Timer duration hết hạn | `load_id` |
| `cycle_ended` | Cycle hoàn tất/bị hủy | `load_id`, `reason`: `completed`\|`superseded`\|`manual`\|`disabled`\|`interlock`\|`estop`\|`all_off` |
| `emergency_stop` | E-STOP được chốt | `source`, `loads_off` |
| `emergency_released` | E-STOP được release | — |
| `interlock_tripped` | Safety Interlock ngắt tải | `after_s` |
| `interlock_cleared` | Kênh điều khiển ổn định lại (RF-05) | — |
| `errors_changed` | `sys_error_mask` đổi | `code_mask`, `added[]`, `cleared[]` |
| `net_switched` | Chuyển ETH↔Wi-Fi | `from`, `to` |
| `config_changed` | Config đã commit NVS | `kind`: `sensor`\|`load_name`\|`load_control`; sensor có `interface_type`/`interface_index`, load có `load_id`; load_control thêm `enabled` |
| `low_heap` | Free heap < 20 KB (hysteresis: xóa khi > 24 KB), tối đa 1/60 s | `free`, `min_free` |
| `time_synced` | `BIT_TIME_VALID` 0→1 | — |
| `reboot` | Sau boot, ngay khi ONLINE | `reason` (từ `esp_reset_reason()`: `power`,`wdt`,`brownout`,`panic`,`sw`) |
| `DIAGNOSTIC` | Event ngay sau khi MQTT ONLINE; đọc từ checkpoint NVS của lần boot/runtime trước | `boot_count`, `reset_reason`, `reset_reason_code`, `error_mask`, `errors.code_mask`, `errors.messages[]`, `mqtt_state`, `network_state`, `interlock_tripped`, `emergency_active`, `uptime_ms`, `free_heap`, `min_free_heap` |

Lý do cần `load_changed`: tải có thể đổi không do lệnh của app (hết timer, interlock, nút bấm) — app khác dùng cùng `user_id` phải đồng bộ được.
