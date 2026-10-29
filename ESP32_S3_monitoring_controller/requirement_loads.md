# requirement_loads.md — Đặc tả điều khiển tải (Load Control)

| Mục | Giá trị |
| --- | --- |
| Phiên bản | 1.2-draft |
| Ngày | 2026-10-08 |
| Dự án | Aquaculture pond monitoring controller — ESP32-S3-WROOM-1U, ESP-IDF v5.2.x |
| Phạm vi | Điều khiển 4 tải (`load_id` 1..4): bật/tắt từ xa, hẹn giờ trễ một lần, lịch tuần và điều kiện cảm biến có thể cùng cấu hình, enable/disable, tắt khẩn cấp. Bao gồm `app_control` (P5), parser trong `app_mqtt`, schema NVS trong `app_nvm`, hook trong `app_modbus`/`app_sysmon`, và yêu cầu cho Mobile App |
| Nguồn | (1) yêu cầu bổ sung của chủ dự án (2026-10-08); (2) `json_payoad.md` v1.3; (3) `requirements.md`; (4) `requirement_mqtt.md`; (5) ảnh màn hình `load_control.jpg` (màn hình "Load 1 · Bơm nước") |
| Đối tượng đọc | AI agent làm Code / Test / Review và team Mobile App |
| Trạng thái code | P5 `app_control` đã có GPIO owner, queue task, SET_STATE/timed cycle, weekly UTC scheduler, enable policy, interlock, E-STOP latch/NVS và runtime/snapshot hooks; S3 build pass. **Chưa chạy hardware acceptance.** P4 `app_modbus` chưa tồn tại nên E-STOP chỉ phát `BIT_SYS_ESTOP`; suspend/resume polling thực tế còn chờ P4. |

---

## 0. Cách dùng tài liệu này

### 0.1 Từ khóa và nhãn (kế thừa `requirement_mqtt.md` mục 0)

- **MUST / MUST NOT**: bắt buộc. **SHOULD**: mặc định phải làm. **MAY**: tùy chọn.
- `[CONFIRMED]`: chủ dự án đã nêu hoặc đã có trong tài liệu hiện hành. Không tự đổi.
- `[PROPOSED]`: đề xuất của tài liệu này vì yêu cầu gốc để trống; **áp dụng mặc định** để không bị chặn.
- `[DECISION-REQUIRED]`: cần chủ dự án quyết (mục 4). Mỗi mục có "mặc định áp dụng tạm".

### 0.2 Thứ tự ưu tiên nguồn khi mâu thuẫn

Yêu cầu bổ sung của chủ dự án (2026-10-08) > `requirement_loads.md` (tài liệu này) > `json_payoad.md` (contract JSON chi tiết) > `requirement_mqtt.md` > `requirements.md` > `pipline.md` (mô tả hiện thực, không phải yêu cầu).

Khi tài liệu này thêm hoặc đổi contract (JSON, struct, topic), phải sửa **đồng thời** các file ở mục 14.

### 0.3 Nguyên tắc an toàn xuyên suốt

Khi gặp điểm chưa rõ: chọn hướng **an toàn = tải OFF, từ chối lệnh nghi ngờ**, ghi vào `pipline.md` → Blocking Decisions, rồi làm tiếp bằng mặc định ở mục 4.

---

## 1. Mục tiêu và phạm vi

| # | Tính năng | Nguồn |
| --- | --- | --- |
| F1 | **Bật/tắt từ xa** từng tải qua MQTT | `[CONFIRMED]` |
| F2 | **Hẹn giờ trễ một lần** (bật trễ rồi tắt sau `duration`; tắt trễ rồi bật lại sau `duration`), đơn vị phút, tính từ lúc thiết bị nhận lệnh; `duration=0` nghĩa là không đổi trạng thái lần hai; sau khi chạy xong thì **reset** cặp giá trị | `[CONFIRMED]` |
| F3 | **Lịch tuần** theo ngày trong tuần (giờ bật/giờ tắt), lưu NVM riêng từng tải, đến giờ thuộc ngày đã chọn thì phải thực hiện | `[CONFIRMED]` |
| F4 | **Enable/Disable** quyền điều khiển từng tải; disable đưa tải về mức LOW; lệnh gửi **ngay** khi người dùng gạt switch trên app, disable sẽ xóa hết config cũ | `[CONFIRMED]` |
| F5 | **Tắt khẩn cấp (E-STOP)**: tắt tất cả tải và tất cả cảm biến | `[CONFIRMED]` (chi tiết hành vi: `[PROPOSED]`) |
| F6 | Mỗi tải có thể bật/tắt theo hai điều kiện cảm biến độc lập; cấu hình bền trong NVS | `[CONFIRMED]` (operator, ưu tiên, ID và full-replace theo mặc định tài liệu này) |

Ngoài phạm vi: thuật toán failover mạng, driver Modbus, BLE provisioning (xem `requirement_mqtt.md` mục 1.2). BLE **không** tham gia điều khiển tải (D-01 của `requirement_mqtt.md`); mọi lệnh trong tài liệu này đi qua MQTT.

---

## 2. Định nghĩa

| Thuật ngữ | Ý nghĩa |
| --- | --- |
| Tải (load) | Một đầu ra DO điều khiển relay/SSR. `load_id` 1..4 (1-based) ↔ DO1..DO4 (GPIO39–42 theo `pipline.md`; thứ tự xác nhận trong `main/defines.h`). Mức HIGH = ON, **LOW = OFF** |
| `state` | Trạng thái **thực** của output. Không suy ra `enabled` từ `state` và ngược lại |
| `enabled` | Quyền điều khiển tải. `false` ⇒ tải bị ép LOW và từ chối lệnh điều khiển |
| Lệnh tay | `SET_STATE` hoặc `SET_LOAD_CYCLE` |
| Lệnh tay đang chạy | Có cycle đang chờ/đang đếm của tải đó, hoặc có `duration_min` tự tắt đang đếm |
| Cycle | Hẹn giờ trễ một lần của `SET_LOAD_CYCLE`, chỉ lưu RAM |
| Lịch tuần | `load_control_cfg_t` lưu NVS, thời gian UTC |
| Điều kiện cảm biến | Rule bật và rule tắt lưu NVS theo từng tải; so sánh giá trị chính `v1` của sample hợp lệ |
| E-STOP | Trạng thái chốt (latched) do `EMERGENCY_STOP`; chỉ thoát bằng `EMERGENCY_RELEASE` |
| Interlock | Safety Interlock của `app_control`: mất kênh điều khiển quá `safety_timeout_s` (mặc định 300 s) thì tắt mọi tải |

---

## 3. Đối chiếu với tài liệu hiện có — điểm lệch và điểm cần chú ý

| # | Phát hiện | Tác động | Xử lý trong tài liệu này |
| --- | --- | --- | --- |
| G-L1 | E-STOP trước đây chưa có trong contract | Đã xử lý trong code/schema | `EMERGENCY_STOP` / `EMERGENCY_RELEASE`, ACK và snapshot đã được thêm; suspend polling thực tế còn chờ P4 |
| G-L2 | **Màn hình "Lịch hẹn" trên app thiếu bộ chọn ngày trong tuần và công tắc bật/tắt lịch.** Contract bắt buộc `days_mask` và `schedule_enabled`; yêu cầu F3 cũng cần chọn ngày | App không gửi được config hợp lệ khi `schedule_enabled=true` | Mục 10.3 |
| G-L3 | **`days_mask` tính theo ngày UTC của mốc BẬT.** Đổi giờ địa phương sang UTC có thể làm lệch ngày (UTC+7: 06:00 sáng thứ Hai = 23:00 Chủ nhật UTC) | Lịch chạy sai ngày nếu app chỉ đổi giờ mà không xoay mask | Mục 6.4.5 và 10.4 |
| G-L4 | **Interlock có thể giết lịch/cycle đang chạy.** Mất kênh điều khiển > 300 s thì mọi tải OFF và không tự bật lại, kể cả tải đang chạy theo lịch tuần cục bộ | Lịch tuần mất ý nghĩa "chạy tự động khi mất mạng" | D-L03 |
| G-L5 | **Không phát bù sau reboot.** Nếu mất điện lúc 10:00 trong cửa sổ lịch 06:00–18:00, tải ở OFF đến lần bật kế tiếp | Máy bơm/sục khí có thể ngừng nhiều giờ | D-L04 |
| G-L6 | **Disable xóa lịch.** Contract chuẩn hóa `schedule_enabled=false`, `days_mask=0` khi `enabled=false`; bật lại không khôi phục lịch | Người dùng mất lịch khi chỉ muốn tạm khóa | D-L05 |
| G-L7 | Snapshot `loads[]` trước đây thiếu cycle state | Đã xử lý trong code | `cycle_mode`, `cycle_next`, `cycle_delay_min`, `cycle_duration_min` được serialize; broker/target verification pending |
| G-L8 | **Config là full-replace** nên enable toggle và "Áp dụng lịch hẹn" ghi đè lẫn nhau nếu gửi đồng thời hoặc dùng dữ liệu cũ | Mất cấu hình âm thầm | Mục 10.2 (tuần tự hóa, đọc-sửa-ghi từ snapshot mới nhất) |
| G-L9 | **Cycle chỉ lưu RAM** nên mất khi reboot/mất điện (đúng với "chỉ thực hiện 1 lần") | App cần biết cycle không bền | Mục 6.3.6 |
| G-L10 | Nút ⇅ giữa hai ô thời gian trên màn hình chưa được định nghĩa trong tài liệu nào | Hành vi UI mơ hồ | D-L10 |
| G-L11 | AC-07 trong `requirements.md` chưa bao phủ E-STOP, thứ tự ưu tiên và các trường hợp biên | Thiếu kiểm thử | Mục 13 |

---

## 4. Sổ quyết định

| ID | Nội dung | Trạng thái | **Mặc định áp dụng tạm** |
| --- | --- | --- | --- |
| D-L01 | Mốc 0 của delay = lúc thiết bị **chấp nhận** lệnh (không phải lúc app bấm gửi), đo bằng đồng hồ đơn điệu `esp_timer`, không phụ thuộc SNTP | `[CONFIRMED]` theo ví dụ "10 phút sau kể từ khi gửi config" | Giữ |
| D-L02 | Cycle không lưu NVS; reboot hủy cycle; tải về LOW khi boot | `[PROPOSED]` | Giữ |
| D-L03 | Khi Interlock đang `tripped`: mốc lịch **BẬT** và bước **BẬT** của cycle bị chặn; mốc TẮT vẫn chạy | `[DECISION-REQUIRED]` | Chặn (an toàn). Phương án khác: cho lịch tiếp tục khi nguyên nhân chỉ là mất mạng |
| D-L04 | Sau boot/khôi phục giờ, lịch **không** phát bù mốc đã qua | `[CONFIRMED]` trong `json_payoad.md` | Giữ. Phương án khác: khôi phục tải ON nếu giờ hiện tại nằm trong cửa sổ |
| D-L05 | Disable xóa `schedule_enabled`, `days_mask` và hai cờ điều kiện (giữ nguyên giá trị cấu hình không hoạt động) | `[CONFIRMED]` cho lịch; mở rộng tương ứng cho rule | Giữ; app **MUST** cảnh báo trước khi disable tải đang dùng tự động hóa |
| D-L06 | Trạng thái E-STOP được lưu NVS và giữ qua reboot | `[PROPOSED]` | Lưu ở key riêng `estop` trong namespace `app_cfg` (không đổi layout `app_config_t`, không tăng schema) |
| D-L07 | "Tắt cảm biến" = dừng toàn bộ thu thập (RS485 + analog 4-20 mA), không cắt nguồn cảm biến (chưa có chân điều khiển nguồn trong spec) | `[DECISION-REQUIRED]` | Dừng thu thập bằng phần mềm. Nếu phần cứng có nguồn cảm biến điều khiển được: bổ sung GPIO vào `defines.h` và kéo xuống LOW |
| D-L08 | Phát hành E-STOP bằng lệnh `EMERGENCY_RELEASE` kèm `confirm:true`; tải **không** tự khôi phục | `[PROPOSED]` | Giữ |
| D-L09 | Lệnh `SET_STATE` không kèm `duration_min` không phải "lệnh tay đang chạy"; mốc lịch đến sau đó vẫn ghi đè | `[PROPOSED]` | Giữ |
| D-L10 | Nút ⇅ trên app | `[DECISION-REQUIRED]` | Hoán đổi mode BẬT/TẮT |
| D-L11 | Kiểu nhấn E-STOP trên app | `[PROPOSED]` | Giữ nút 1 giây (không dùng hộp thoại xác nhận chậm) |
| D-L12 | Tải bị `enabled=false` mà NVS ghi lỗi khi disable | `[PROPOSED]` | Vẫn áp dụng disable ở RAM (fail-safe), ACK `storage_error`, set `SYS_ERR_NVM_FAIL` |
| D-L13 | Kiểu LED khi E-STOP | `[PROPOSED]` | LED_ERROR nháy 0,5 Hz; ưu tiên: Fatal/NVM > E-STOP > Modbus > Net/MQTT |
| D-L14 | Lịch tuần và điều kiện cảm biến cùng một tải | `[CONFIRMED]` theo lựa chọn chủ dự án | Không cho phép bật đồng thời; parser và NVS validator từ chối |
| D-L15 | Hai điều kiện cảm biến cùng khớp một sample | `[PROPOSED]` | OFF thắng; chỉ áp dụng trên sample mới, hợp lệ |

---

## 5. Mô hình trạng thái và thứ tự ưu tiên

### 5.1 Trạng thái từng tải

**Cấu hình bền (NVS, schema v3):** `load_control_cfg_t` chứa quyền, lịch tuần và hai rule cảm biến (ON/OFF); schema v1/v2 được migrate với rule cảm biến tắt mặc định. `load_name[32]` được lưu cùng.

**Trạng thái chạy (RAM, `app_control` sở hữu, không lưu):**

| Thành phần | Nội dung |
| --- | --- |
| `output` | Mức GPIO thực |
| `auto_off_deadline_us` | Hạn tự tắt của `SET_STATE` có `duration_min` (0 = không có) |
| `cycle_mode` | `NONE` / `ON_THEN_OFF` / `OFF_THEN_ON` |
| `cycle_phase` | `IDLE` → `WAIT_FIRST` (đang đếm delay) → `WAIT_SECOND` (đang đếm duration) → `IDLE` |
| `cycle_deadline_us` | Hạn của bước kế tiếp, so với `esp_timer_get_time()` |
| `cycle_delay_min`, `cycle_duration_min` | Cặp giá trị đã nhận, để echo ACK/snapshot; **xóa về 0** khi cycle kết thúc hoặc bị hủy |
| `last_sched_minute` | Phút epoch cuối cùng đã được đánh giá lịch (chống bắn lặp) |

Trạng thái toàn hệ thống: `BIT_SYS_ESTOP` (E-STOP chốt), `BIT_SYS_INTERLOCK_TRIPPED`, `BIT_TIME_VALID`.

### 5.2 Thứ tự ưu tiên (cao → thấp)

| Mức | Nguồn | Tác dụng lên tải |
| --- | --- | --- |
| 1 | **E-STOP** (`EMERGENCY_STOP`) | Ép mọi tải LOW, dừng cảm biến, hủy mọi cycle/timer, chặn mọi lệnh bật cho đến khi `EMERGENCY_RELEASE` |
| 2 | **Nút Factory Reset** (giữ ≥ 5 s, nhả, giữ lại 5 s trong 2 s) | 4 relay LOW rồi xóa NVS (đã có trong `requirements.md`) |
| 3 | **Disable** (`enabled=false`) | Ép tải đó LOW, hủy cycle/lịch, từ chối lệnh điều khiển, reset config |
| 4 | **Interlock** | Ép mọi tải LOW, hủy cycle; chặn bước BẬT (D-L03) |
| 5 | ` ` | Tắt mọi tải, hủy timer; luôn được phép (kể cả `enabled=false`, interlock; **không** chốt trạng thái) |
| 6 | Lệnh tay: `SET_STATE`, `SET_LOAD_CYCLE` | Điều khiển tải; lệnh mới của cùng tải thay lệnh cũ |
| 7 | **Điều kiện cảm biến** | Chạy khi không có hẹn giờ trễ; ưu tiên cao hơn lịch tuần |
| 8 | **Lịch tuần** | Có thể bật cùng điều kiện cảm biến; chỉ thực hiện tại phút lịch và bị bỏ qua nếu điều kiện đang tác động |

Quy tắc kết hợp:

- Hẹn giờ trễ đang chạy ⇒ bỏ qua đánh giá điều kiện và lịch cho tải đó. Khi hẹn giờ kết thúc, các kịch bản tự động được xét lại theo chu kỳ tương ứng.
- Điều kiện cảm biến được đánh giá trên sample mới hợp lệ và có ưu tiên hơn lịch tuần. Nếu một điều kiện đang khớp tại đúng phút lịch bật/tắt, sự kiện lịch đó bị bỏ qua, không hoãn và không chạy bù khi điều kiện ngừng khớp hoặc bị tắt.
- Mốc lịch rơi vào lúc hẹn giờ trễ đang chạy bị bỏ qua, không hoãn và không phát bù.
- Lệnh điều khiển thủ công `SET_STATE` tắt các điều kiện và lịch đang bật của tải đó; hẹn giờ trễ là lệnh điều khiển riêng và có quyền ưu tiên hơn các tự động trong thời gian chạy.
- `SET_STATE` mới **hủy** cycle đang chờ của cùng tải `[PROPOSED]`.
- `SET_LOAD_CYCLE` mới **hủy** cycle đang chờ và `auto_off_deadline` của cùng tải.
- E-STOP, disable và interlock đều hủy cycle; chỉ lịch tuần trong NVS còn lại (trừ disable xóa lịch theo D-L05).

---

## 6. Yêu cầu chức năng

### 6.1 Trạng thái mặc định khi khởi động (LC-PWR)

| ID | Yêu cầu |
| --- | --- |
| LC-PWR-01 | Trước khi tạo bất kỳ task nào, `main` **MUST** cấu hình 4 chân DO ở mức LOW. Không có glitch HIGH khi boot/reset/brownout. |
| LC-PWR-02 | Sau boot tất cả tải **MUST** ở OFF; không khôi phục trạng thái ON trước đó (xem D-L04). |
| LC-PWR-03 | Boot đọc `load_control[]` và key `estop` từ NVS. Tải có `enabled=false` giữ LOW và từ chối lệnh. |
| LC-PWR-04 | Nếu `estop` đang chốt: tải LOW, **không** khởi động thu thập cảm biến, MQTT vẫn chạy để nhận `EMERGENCY_RELEASE`. |
| LC-PWR-05 | Cycle và `auto_off` không tồn tại sau reboot (D-L02). |

### 6.2 Bật/tắt từ xa (LC-REM)

| ID | Yêu cầu |
| --- | --- |
| LC-REM-01 | `SET_STATE` (topic `commands`) đổi relay tức thời theo `state`. Contract: `json_payoad.md` mục 2. |
| LC-REM-02 | `duration_min` 0..86400; `0` = không tự tắt. Chỉ hợp lệ khi `state=true`; `state=false` kèm `duration_min>0` ⇒ `invalid_value`. |
| LC-REM-03 | Tải `enabled=false` ⇒ ACK `forbidden`, relay không đổi. |
| LC-REM-04 | E-STOP đang chốt ⇒ ACK `emergency_active`, relay không đổi. |
| LC-REM-05 | Lệnh idempotent: bật tải đang ON hoặc tắt tải đang OFF trả `ok`, không đổi GPIO, ghi nhận `changed=false` nếu có. |
| LC-REM-06 | ACK chỉ gửi **sau khi** relay đã được điều khiển; `load.state` là trạng thái đọc lại từ `app_control`. |
| LC-REM-07 | Mỗi lần output đổi (bất kể nguyên nhân) phải phát `event load_changed` kèm `source` (mục 8.4). |
| LC-REM-08 | Lệnh có thể đến khi interlock đang `tripped` chỉ sau khi kênh MQTT phục hồi và interlock đã `cleared`; trước đó trả `interlock_active`. |
| LC-REM-09 | DI được cấu hình với tên `DO1_...` .. `DO4_...` là feedback của tải tương ứng; DI=1 (chân kéo xuống GND) nghĩa là ON. |
| LC-REM-10 | Với DI feedback đang bật, `SET_LOAD_STATE` chỉ ACK `ok` sau khi feedback khớp trạng thái yêu cầu; chờ tối đa 2 giây. Quá hạn thì giữ nguyên output đã ra lệnh, ACK lỗi và đưa trạng thái feedback quan sát được lên app. |
| LC-REM-11 | Thay đổi feedback DI do điều khiển ngoài app phát `load_changed` (`source:"feedback"`); snapshot phải báo trạng thái feedback. Khi đổi tên DI bỏ tiền tố `DOx_`, DI trở lại cảm biến thường và lệnh dùng logic GPIO hiện tại. |
| LC-REM-12 | DI feedback không xuất hiện trong danh sách cảm biến vận hành/diagnostics của app nhưng vẫn xuất hiện trong quản lý cảm biến; telemetry feedback cập nhật trạng thái tải trên app. |
| LC-REM-13 | Tải đang `enabled=false` mà feedback chuyển sang ON (bật thủ công tại tủ) thì firmware bật lại `enabled=true`, ghi NVM (RAM + flash), đặt output theo trạng thái thực và phát `load_changed` để snapshot gửi `enabled=true` lên app. Nếu ghi NVM lỗi thì giữ nguyên `enabled=false` và ghi log lỗi. |
| LC-REM-14 | Sau mỗi chu kỳ đọc cảm biến, nếu giá trị hoặc tính hợp lệ của bất kỳ DI nào đổi so với chu kỳ trước, firmware gửi telemetry ngay (không chờ `telemetry_interval_s`) và đặt lại mốc gửi định kỳ kế tiếp. |
| LC-REM-15 | DI `configured=true, enabled=true` có tên `ON1_...` .. `ON4_...` hoặc `OFF1_...` .. `OFF4_...` là nút momentary cho DO tương ứng. Cạnh nhấn active-low được nhận bằng GPIO falling-edge interrupt và debounce 40 ms; nhấn ON bật, nhấn OFF tắt. Lệnh nút và công tắc tải trên app ngang ưu tiên; lệnh mới nhất thắng. Nhả nút không phát lệnh. |
| LC-REM-16 | DI `ONx_`/`OFFx_` là reserved control input: ẩn khỏi danh sách cảm biến vận hành và diagnostics, nhưng vẫn hiện/chỉnh sửa được trong quản lý/cấu hình cảm biến. Disable DI hoặc đổi tên bỏ tiền tố thì lần nhấn không còn điều khiển tải. |

### 6.3 Hẹn giờ trễ một lần (LC-CYC)

#### 6.3.1 Ngữ nghĩa

| Mode | Bước 1 | Bước 2 |
| --- | --- | --- |
| `ON_THEN_OFF` | Chờ `on_delay_min` rồi **BẬT** | Giữ ON `duration` phút rồi **TẮT**. `duration=0` ⇒ giữ ON vô thời hạn (không có bước 2) |
| `OFF_THEN_ON` | Chờ `off_delay_min` rồi **TẮT** | Giữ OFF `duration` phút rồi **BẬT lại**. `duration=0` ⇒ giữ OFF vô thời hạn |

Ví dụ chuẩn: `ON_THEN_OFF`, `on_delay_min=10`, `duration=20` ⇒ 10 phút sau khi thiết bị nhận lệnh tải bật; 20 phút sau đó tải tắt. Với `duration=0` tải bật sau 10 phút và không bao giờ tự tắt. Tương tự cho `OFF_THEN_ON`.

#### 6.3.2 Yêu cầu

| ID | Yêu cầu |
| --- | --- |
| LC-CYC-01 | Cycle là **một command riêng** `SET_LOAD_CYCLE` gửi tới `commands`; **không** lưu thành lịch tuần, **không** ghi NVS. |
| LC-CYC-02 | Miền: `on_delay_min`/`off_delay_min` và `duration` là integer 0..1440. Ngoài miền hoặc không phải integer ⇒ `invalid_value`. Thiếu `mode`, thiếu delay của mode đã chọn, hoặc thiếu `duration` ⇒ `invalid_fields`. Delay của mode **không** được chọn bị bỏ qua. |
| LC-CYC-03 | `mode` phân biệt hoa/thường, chỉ nhận `ON_THEN_OFF`, `OFF_THEN_ON`. Giá trị khác ⇒ `invalid_value`. |
| LC-CYC-04 | Mốc 0 là lúc thiết bị chấp nhận lệnh (D-L01). Thời hạn tính bằng `int64` micro giây từ `esp_timer_get_time()`; **không** dùng `time()` nên SNTP nhảy giờ không làm lệch cycle. |
| LC-CYC-05 | Delay = 0 ⇒ thực hiện bước 1 **ngay** trước khi gửi ACK. |
| LC-CYC-06 | Trong lúc chờ bước 1, tải **giữ nguyên trạng thái hiện tại**. Nếu bước 1 trùng trạng thái hiện tại (đã ON mà bước là BẬT) thì không đổi GPIO nhưng **vẫn bắt đầu** đếm `duration`. |
| LC-CYC-07 | Cycle mới của cùng tải **hủy** cycle đang chờ và `auto_off` cũ. Cycle của tải khác độc lập. |
| LC-CYC-08 | Sau khi hoàn tất (hoặc `duration=0` và bước 1 đã xong) hoặc bị hủy: **reset** `cycle_mode=NONE`, `cycle_delay_min=0`, `cycle_duration_min=0`, `remaining_s=0` và phát `event cycle_ended` (mục 8.4). |
| LC-CYC-09 | Cycle bị hủy bởi: cycle/`SET_STATE` mới, disable, interlock, E-STOP, ` `, factory reset, reboot. |
| LC-CYC-10 | `remaining_s` trong ACK/snapshot = số giây còn lại đến bước chuyển tiếp **kế tiếp**; `0` khi không có bước nào đang chờ. |
| LC-CYC-11 | Khi tải `enabled=false` ⇒ `forbidden`; khi E-STOP ⇒ `emergency_active`. |
| LC-CYC-12 | Mốc lịch tuần đến lúc cycle đang chờ/đang chạy bị bỏ qua (mục 6.4.4). |

#### 6.3.3 Trường hợp biên

| Tình huống | Hành vi |
| --- | --- |
| `ON_THEN_OFF`, delay 0, duration 0 | Bật ngay, giữ ON; tương đương `SET_STATE true` |
| `OFF_THEN_ON`, delay 0, duration 0 | Tắt ngay, giữ OFF |
| Delay 1440 + duration 1440 | Tổng 48 giờ hợp lệ; deadline 64-bit, không tràn |
| Hai cycle liên tiếp cùng tải | Cycle thứ hai thay thế; cycle thứ nhất kết thúc với `reason:"superseded"` |
| Mất mạng/MQTT trong lúc cycle chạy | Cycle **tiếp tục** chạy cục bộ cho đến khi interlock trip (nếu có) |
| Interlock trip lúc đang chờ bước BẬT | Hủy cycle, `reason:"interlock"` |
| Đã reboot | Cycle mất (LC-PWR-05); app thấy `cycle_mode:"none"` trong snapshot sau reboot |

#### 6.3.4 Giới hạn

Cycle chỉ lưu RAM nên không chịu được mất điện. Nếu cần vận hành bền qua mất điện hãy dùng lịch tuần.

### 6.4 Lịch tuần (LC-SCH)

#### 6.4.1 Lưu trữ

| ID | Yêu cầu |
| --- | --- |
| LC-SCH-01 | Lịch lưu riêng từng tải trong `app_config_t.load_control[load_id-1]` và NVS (schema v3). Sống sót qua reboot. |
| LC-SCH-02 | `config/set` `type=load_control` là **full-replace**: đủ field lịch và điều kiện được liệt kê tại LC-SEN-02. Thiếu field ⇒ `invalid_fields`. |
| LC-SCH-03 | `schedule_enabled=true` thì `days_mask` ≠ 0, ngược lại ⇒ `invalid_value`. `days_mask` 0..127; bit 0=Mon … bit 6=Sun (theo ngày **UTC**). |
| LC-SCH-04 | `on_time_utc`/`off_time_utc` dạng `HH:mm` (`00:00`–`23:59`), lưu thành phút từ 00:00 UTC (0..1439). |
| LC-SCH-05 | Ghi NVS chỉ khi nội dung thật sự đổi (`config.changed=true`); gửi lại cùng cấu hình không ghi flash (giảm mòn). |
| LC-SCH-06 | Không có giới hạn số lần đặt lịch, nhưng consumer **MUST** áp rate limit chung của `config/set` (`busy` nếu vượt). |

#### 6.4.2 Ngữ nghĩa cửa sổ

- Mỗi ngày UTC có trong `days_mask` bắt đầu một chu kỳ tại `on_time_utc`; tắt tại `off_time_utc`.
- Nếu `off <= on` thì giờ tắt thuộc ngày UTC kế tiếp (`off == on` ⇒ cửa sổ 24 giờ).
- Độ dài cửa sổ = `(off - on) mod 1440`, bằng 1440 khi kết quả là 0.

#### 6.4.3 Thuật toán đánh giá (mỗi phút, mỗi tải)

Tại mỗi **phút epoch mới** `m` (phần nguyên của `time()/60`), với `today`/`yesterday` là thứ UTC (`gmtime_r`) và `hm` là phút trong ngày:

```text
on_mark  = bit(today)     in days_mask AND hm == on_minute_utc
off_mark = (off_minute_utc >  on_minute_utc AND bit(today)     in days_mask AND hm == off_minute_utc)
        OR (off_minute_utc <= on_minute_utc AND bit(yesterday) in days_mask AND hm == off_minute_utc)

nếu on_mark và off_mark cùng phút  -> kết quả ON, KHÔNG đổi relay (cửa sổ 24 giờ nối tiếp)
nếu on_mark  -> bật tải
nếu off_mark -> tắt tải
```

#### 6.4.4 Điều kiện bỏ qua (mốc bị bỏ, không phát bù)

| ID | Điều kiện |
| --- | --- |
| LC-SCH-10 | `enabled=false` hoặc `schedule_enabled=false` |
| LC-SCH-11 | `BIT_TIME_VALID=0` (đồng hồ chưa đồng bộ SNTP) |
| LC-SCH-12 | E-STOP đang chốt |
| LC-SCH-13 | Có lệnh tay đang chạy của tải đó (cycle đang chờ/chạy hoặc `auto_off` đang đếm) |
| LC-SCH-14 | Interlock `tripped` và mốc là **BẬT** (D-L03); mốc TẮT vẫn thực hiện |

Mốc bỏ qua theo LC-SCH-13 **không** hoãn sang sau khi cycle kết thúc.

#### 6.4.5 Giờ địa phương và ngày trong tuần

Firmware chỉ làm việc theo UTC; **app** chịu trách nhiệm đổi giờ địa phương sang UTC **và xoay `days_mask`**:

- Với mỗi ngày địa phương được chọn, tính thời điểm BẬT đã đổi sang UTC; ngày UTC của thời điểm đó là bit cần đặt.
- `off_time_utc` chỉ cần đổi giờ; firmware suy ra ngày TẮT theo quy tắc 6.4.2 (độ dài cửa sổ không đổi vì offset cố định).

Ví dụ (UTC+7): lịch Thứ Hai–Thứ Sáu 06:00–18:00 giờ địa phương ⇒ `on_time_utc="23:00"`, `off_time_utc="11:00"`, ngày bắt đầu theo UTC là Chủ nhật–Thứ Năm ⇒ `days_mask = 64+1+2+4+8 = 79` (không phải 31). Tắt lúc 11:00 UTC ngày hôm sau, tức 18:00 giờ địa phương cùng ngày.

#### 6.4.6 Chống bắn lặp và nhảy giờ

| ID | Yêu cầu |
| --- | --- |
| LC-SCH-20 | Mỗi phút epoch chỉ được đánh giá **một lần** (`last_sched_minute`). |
| LC-SCH-21 | SNTP chỉnh giờ về sau: chỉ đánh giá phút hiện tại, **không** quét lại các phút đã bị nhảy qua. |
| LC-SCH-22 | SNTP chỉnh giờ lùi: không đánh giá lại phút đã đánh giá (chỉ đánh giá khi `m > last_sched_minute`). |
| LC-SCH-23 | Khi `BIT_TIME_VALID` chuyển 0→1: đánh giá phút hiện tại; mốc thuộc các phút trước đó là mốc đã qua. |
| LC-SCH-24 | Độ trễ từ mốc đến lúc đổi relay ≤ 2 s (vòng lặp kiểm tra ≤ 1 s). |

### 6.5 Enable / Disable (LC-EN)

| ID | Yêu cầu |
| --- | --- |
| LC-EN-01 | `enabled` là quyền điều khiển, **không** phải trạng thái relay. Gửi bằng `config/set` `type=load_control` (full-replace). |
| LC-EN-02 | Khi `enabled=false`, theo thứ tự: (1) kéo tải về **LOW**; (2) hủy cycle, `auto_off`; (3) chuẩn hóa `schedule_enabled=false`, `days_mask=0` và hai cờ điều kiện=false (D-L05); (4) ghi NVS; (5) ACK `kind=config`; (6) phát `load_changed` (`source:"disable"`) nếu output thật sự đổi và `config_changed`. |
| LC-EN-03 | Bước (1) **MUST NOT** chờ NVS. Độ trễ từ lúc nhận message đến lúc chân LOW ≤ 200 ms (không tính độ trễ mạng). |
| LC-EN-04 | Nếu NVS ghi lỗi khi disable: vẫn giữ tải LOW và giữ `enabled=false` ở RAM (fail-safe, D-L12), ACK `storage_error`, set `SYS_ERR_NVM_FAIL`. |
| LC-EN-05 | Khi `enabled=true`: chỉ cập nhật quyền (và lịch theo payload) sau khi ghi NVS thành công; lỗi NVS ⇒ giữ nguyên cấu hình cũ, ACK `storage_error`. **Không** tự bật tải. |
| LC-EN-06 | Khi `enabled=false`: từ chối `SET_STATE`/`SET_LOAD_CYCLE` bằng `forbidden`. ` ` và E-STOP vẫn được phép. |
| LC-EN-07 | `enabled` lưu bền; sau reboot tải `enabled=false` vẫn bị khóa. |
| LC-EN-08 | Lệnh enable/disable được gửi **ngay khi người dùng gạt switch** (mục 10.2), không chờ nút xác nhận. |
| LC-EN-09 | Default khi migrate NVS v1/v2/v3→v4: giữ quyền/lịch/rule cảm biến có sẵn; rule cảm biến ở v1/v2 mặc định tắt. Default thiết bị mới sau factory reset: mọi tải `enabled=true`, lịch và rule cảm biến tắt. |
| LC-EN-10 | `enabled` của tải này không ảnh hưởng tải khác. |

### 6.6 Tắt khẩn cấp E-STOP (LC-ES) `[PROPOSED]` theo yêu cầu F5

#### 6.6.1 Lệnh

| Action | Topic | Mô tả |
| --- | --- | --- |
| `EMERGENCY_STOP` | `commands` | Kích hoạt E-STOP (chốt) |
| `EMERGENCY_RELEASE` | `commands` | Thoát E-STOP; bắt buộc `"confirm":true` (D-L08) |

` ` giữ nguyên là lệnh **chỉ tắt tải, không chốt**. E-STOP là tập cha: tắt tải **và** dừng cảm biến **và** chốt.

#### 6.6.2 Hành vi khi kích hoạt (theo thứ tự)

| Bước | Hành động | Ghi chú |
| --- | --- | --- |
| 1 | Kéo cả 4 DO về LOW | Bất kể `enabled`, interlock, cycle, lịch |
| 2 | Hủy mọi cycle và `auto_off`; phát `cycle_ended` (`reason:"estop"`) cho tải có cycle | |
| 3 | Set `BIT_SYS_ESTOP` | Chặn mọi lệnh bật và mốc lịch |
| 4 | Dừng thu thập cảm biến: tạm ngưng polling RS485 (nhả DE/RE về nhận), dừng lấy mẫu analog 4-20 mA | D-L07; **không** sửa `enabled` của cảm biến trong NVS |
| 5 | Ghi key `estop=1` vào NVS (sau bước 1) | D-L06 |
| 6 | Phát ACK `kind=emergency`, `event emergency_stop`, và một `snapshot` ngay | |

#### 6.6.3 Yêu cầu

| ID | Yêu cầu |
| --- | --- |
| LC-ES-01 | Tải về LOW ≤ 100 ms kể từ khi `mqtt_client_task` nhận message (không tính độ trễ mạng). |
| LC-ES-02 | E-STOP **MUST** thành công kể cả khi `load_cmd_queue` đầy, tải `enabled=false`, thời gian chưa đồng bộ, interlock đang trip hoặc lệnh bị coi là cũ. Parser gọi API đồng bộ của `app_control` (mutex ngắn), không đi qua `load_cmd_queue`. Không áp `expired`, rate limit, hay `busy`. |
| LC-ES-03 | Idempotent: gửi lại khi đã chốt trả `ok` với `changed:false`. Cho phép app thử lại cùng `cmd_id` đến khi nhận ACK. |
| LC-ES-04 | Khi E-STOP đang chốt: `SET_STATE`, `SET_LOAD_CYCLE` ⇒ `emergency_active`; mốc lịch bị bỏ (LC-SCH-12). ` `, `GET_STATUS` và mọi `config/set` vẫn được chấp nhận (config chỉ lưu, không điều khiển tải; cấu hình cảm biến có hiệu lực sau release). |
| LC-ES-05 | Trong lúc E-STOP, `telemetry` vẫn gửi theo chu kỳ; mỗi mục `sensors[]` có `valid:false` và `error:"stopped"` để app giữ định danh interface. **Không** set `SYS_ERR_MODBUS_TIMEOUT` và không nháy LED 4 Hz vì lỗi Modbus. |
| LC-ES-06 | `app_sysmon` hiển thị LED_ERROR theo D-L13; LED_LOAD tắt (không còn tải ON). |
| LC-ES-07 | E-STOP giữ qua reboot (D-L06): boot với `estop=1` thì tải LOW, không khởi động thu thập, MQTT chạy để nhận release. Lỗi đọc key `estop` khác `NOT_FOUND` ⇒ coi như đang chốt (fail-safe) và set `SYS_ERR_NVM_FAIL`. |
| LC-ES-08 | Factory reset (giữ ≥ 5 s, nhả, giữ lại 5 s trong 2 s) xóa trạng thái E-STOP cùng NVS. |
| LC-ES-09 | `EMERGENCY_RELEASE`: xóa `BIT_SYS_ESTOP`, xóa key `estop`, khởi động lại thu thập cảm biến (mẫu đầu `error:"not_ready"` đến khi hợp lệ), phát `event emergency_released` + ACK. **Tải vẫn OFF**, không tự khôi phục; lịch tuần đánh giá lại từ phút kế tiếp, không phát bù. |
| LC-ES-10 | `EMERGENCY_RELEASE` thiếu `confirm:true` ⇒ `invalid_fields`; khi không ở trạng thái E-STOP ⇒ `ok`, `changed:false`. |
| LC-ES-11 | `app_modbus` **MUST** cung cấp `app_modbus_suspend()`/`app_modbus_resume()` (không block quá 1 chu kỳ polling, thread-safe với `modbus_uart_mutex`); E-STOP không chờ transaction Modbus đang dở quá 100 ms (tải đã LOW trước). |
| LC-ES-12 | MAY: nút vật lý E-STOP (chưa có trong spec; nếu thêm, phải đi qua cùng API với lệnh MQTT). |

### 6.7 Tương tác với Safety Interlock (LC-IL)

| ID | Yêu cầu |
| --- | --- |
| LC-IL-01 | Interlock kích hoạt: mọi tải LOW, hủy mọi cycle (`reason:"interlock"`), set `BIT_SYS_INTERLOCK_TRIPPED`, phát `interlock_tripped`. |
| LC-IL-02 | Khi kênh phục hồi, tải **không** tự bật lại; chờ lệnh mới hoặc mốc lịch BẬT kế tiếp (D-L03, D-L04). |
| LC-IL-03 | Lịch TẮT và cycle bước TẮT vẫn thực hiện khi interlock đang `tripped`. |
| LC-IL-04 | Việc chuyển quyền sở hữu interlock từ `app_mqtt` (tạm, `TODO(P5)`) sang `app_control` **MUST** hoàn tất khi hiện thực tài liệu này; `app_mqtt` không được chạm GPIO relay ở bản cuối. |

### 6.8 Điều kiện cảm biến (LC-SEN)

| ID | Yêu cầu |
| --- | --- |
| LC-SEN-01 | Mỗi tải có tối đa một điều kiện ON và một điều kiện OFF, độc lập sensor/operator/ngưỡng; lưu cùng `load_control[load_id-1]` trong NVS schema v3. |
| LC-SEN-02 | Full-replace `config/set type=load_control` bắt buộc đủ `on_condition_enabled`, `on_sensor_id`, `on_operator`, `on_threshold`, `off_condition_enabled`, `off_sensor_id`, `off_operator`, `off_threshold`, cả khi rule disabled. Thiếu/sai kiểu ⇒ `invalid_fields`; sai ID/operator/miền ⇒ `invalid_value`. |
| LC-SEN-03 | ID ổn định: `sensor_001`…`sensor_004` lần lượt RS485 `interface_index` 0…3; `sensor_005` là analog index 0. Cùng ID được xuất trong telemetry và snapshot. |
| LC-SEN-04 | Sensor value là `v1`: SHT40 `temp` °C, DO `do_mg_l`, pH `ph_val`, analog `current_ma`. Rule chỉ xét sample mới, `valid=true`, finite và đúng `sensor_id`; sample không hợp lệ/khuyết đưa tải về OFF. |
| LC-SEN-05 | Toán tử phân biệt chữ thường: `lt`, `lte`, `eq`, `gte`, `gt`; threshold số hữu hạn trong [-1,000,000, 1,000,000]. `eq` dùng so sánh số thực chính xác; UI nên ưu tiên các toán tử khoảng. |
| LC-SEN-06 | Nếu ON và OFF cùng khớp một chu kỳ sample thì OFF thắng. Nếu không rule nào khớp, giữ nguyên output; mỗi rule khớp thực hiện trạng thái tương ứng. |
| LC-SEN-07 | Lịch tuần và các điều kiện cảm biến được phép cấu hình/bật đồng thời; không từ chối tổ hợp này ở parser hoặc `app_nvm_validate_config()`. |
| LC-SEN-08 | Hẹn giờ trễ đang chạy thì bỏ qua điều kiện cảm biến và lịch tuần. Điều kiện chỉ được xét trên sample mới; E-STOP chặn ON; Interlock cho phép OFF nhưng chặn ON. Rule tiếp tục chạy cục bộ khi MQTT mất kết nối. |
| LC-SEN-09 | Khi `enabled=false`, chuẩn hóa cả hai `*_condition_enabled=false`; không tự bật khi enable lại hoặc reboot cho tới khi nhận sample thỏa rule. |
| LC-SEN-10 | Thay đổi output do điều kiện phát `load_changed` với `source:"sensor"`; không thêm action one-shot vào `commands`. Cấu hình persist dùng `config/set`. |
| LC-SEN-11 | Nếu điều kiện đang khớp tại phút thực hiện mốc lịch, lịch không đổi output ở mốc đó và không chạy bù sau khi điều kiện hết khớp/tắt. |
| LC-SEN-12 | Lệnh điều khiển thủ công `SET_STATE` vô hiệu hóa các điều kiện và lịch đang bật của tải; app phải phản ánh cấu hình đã được thiết bị xác nhận. |

---

## 7. Cấu trúc dữ liệu

### 7.1 Đã có (`main/main_data_types.h`)

`load_control_cfg_t`, `load_command_kind_t` (`SET_STATE`, `TIMED_CYCLE`, `SET_ALL_OFF`, `EMERGENCY_STOP`, `EMERGENCY_RELEASE`), `load_cycle_mode_t`, `load_runtime_t`, `load_command_t`, `load_ack_t`, `mqtt_ack_t`, `mqtt_event_t`, `config_update_cmd_t` với `CFG_CMD_UPDATE_LOAD_CONTROL`. Đã có trong `main/main_data_types.h`.

### 7.2 Shared types đã bổ sung

`main/main_data_types.h` hiện có `BIT_SYS_ESTOP`, `LOAD_COMMAND_EMERGENCY_STOP/RELEASE`, `LOAD_ACK_FORBIDDEN/EMERGENCY_ACTIVE`, `MQTT_ACK_EMERGENCY`, `MQTT_ACK_CODE_EMERGENCY_ACTIVE`, cycle phase/runtime state và cycle/emergency event metadata. `load_command_t` mang `duration_min`; cycle chỉ RAM, còn `load_control_cfg_t` là NVS policy theo từng tải.

### 7.3 NVS

- `app_config_t` được tăng lên schema v3 để lưu hai rule sensor mỗi tải. Schema v1 và v2 được migrate, khởi tạo rule sensor disabled; không mất lịch/quyền điều khiển đã lưu.
- Thêm key `estop` (u8, 0/1) trong namespace `app_cfg` (D-L06). `NOT_FOUND` = 0.
- API đề xuất: `app_nvm_set_estop(bool)`, `app_nvm_get_estop(bool *out)`.

### 7.4 API `app_control` đã có

```c
esp_err_t app_control_init(const app_config_t *config);
esp_err_t app_control_emergency_stop(bool *changed, uint8_t *loads_off); /* đồng bộ, không dùng queue */
esp_err_t app_control_emergency_release(bool *changed);
esp_err_t app_control_config_sync(const app_config_t *config);
esp_err_t app_control_sensor_update(const sensor_cycle_t *cycle);
esp_err_t app_control_apply_load_policy(const app_config_t *candidate, uint8_t load_id,
                                        bool *changed, bool *applied_in_ram);
esp_err_t app_control_force_all_off(const char *source);
esp_err_t app_control_get_load_runtime(uint8_t load_id, load_runtime_t *out);
bool      app_control_is_estop(void);
bool      app_control_is_interlock_tripped(void);
void      app_control_interlock_trip(uint32_t after_s);
void      app_control_interlock_clear(void);
```

`app_control_init(config)` configures GPIO39–42 LOW before starting the Core-1 owner task. `app_control_emergency_stop(changed, loads_off)` returns the transitioned-to-off count. `app_control_apply_load_policy()` applies disable to output/RAM before NVS and reports `applied_in_ram` on storage error. `app_control_config_sync()` updates policies after provisioning/config reload.

---

## 8. Hợp đồng thông điệp (thay đổi và bổ sung)

Contract `SET_STATE`, `SET_LOAD_CYCLE`, ` ` và ACK tải/config giữ nguyên. Cấu hình rule sensor được gửi qua `config/set type=load_control` theo full-replace schema v1.3 trong `json_payoad.md`; không có command `commands` mới vì điều kiện được persist và chạy cục bộ.

Ví dụ bật tải 1 khi `sensor_001 < 10`, tắt khi `sensor_001 >= 20`:

```json
{"v":1,"cmd_id":"sensor-rule-01","type":"load_control","load_id":1,"enabled":true,"schedule_enabled":false,"days_mask":0,"on_time_utc":"00:00","off_time_utc":"00:00","on_condition_enabled":true,"on_sensor_id":"sensor_001","on_operator":"lt","on_threshold":10,"off_condition_enabled":true,"off_sensor_id":"sensor_001","off_operator":"gte","off_threshold":20}
```

### 8.1 Lệnh mới (topic `commands`, QoS 1, flat JSON)

```json
{"v":1,"cmd_id":"estop-01","action":"EMERGENCY_STOP"}
```

```json
{"v":1,"cmd_id":"estop-rel-01","action":"EMERGENCY_RELEASE","confirm":true}
```

### 8.2 ACK mới

```json
{"v":1,"cmd_id":"estop-01","kind":"emergency","result":"ok","code":"ok",
 "emergency":{"active":true,"changed":true,"loads_off":4},"dup":false}
```

Lệnh tải bị từ chối khi E-STOP:

```json
{"v":1,"cmd_id":"state-02","kind":"load","result":"error","code":"emergency_active",
 "reason":"emergency stop active","dup":false}
```

Mã lỗi mới `emergency_active` thêm vào bảng 8.3.2 của `requirement_mqtt.md`; giá trị `kind` mới `emergency`.

### 8.3 Snapshot: field bổ sung

Mỗi phần tử `loads[]` thêm (ngoài `load_id, name, state, enabled, remaining_s, schedule_enabled, days_mask, on_time_utc, off_time_utc`):

| Field | Giá trị |
| --- | --- |
| `cycle_mode` | `"none"` \| `"ON_THEN_OFF"` \| `"OFF_THEN_ON"` |
| `cycle_next` | `"on"` \| `"off"` \| `"none"` — bước chuyển tiếp kế tiếp (`remaining_s` đếm tới bước này) |
| `cycle_delay_min`, `cycle_duration_min` | Cặp giá trị đang chạy; `0` khi `cycle_mode:"none"` |
| ON/OFF condition fields | `*_condition_enabled`, `*_sensor_id`, `*_operator`, `*_threshold`; đủ giá trị để app gửi full-replace |

Mỗi phần tử `sensors[]` cũng có `sensor_id` để app tham chiếu nhất quán từ telemetry và snapshot.

Top-level thêm:

```json
"emergency":{"active":true}
```

`loads[]` luôn đủ 4 phần tử (đã quy định ở `requirement_mqtt.md`). `sensors[]` trong lúc E-STOP: `valid:false`, `error:"stopped"` (thêm vào danh sách `timeout|crc|out_of_range|not_ready`).

### 8.4 Event bổ sung (topic `status`, `type:"event"`, QoS 1, không retained)

| `event` | Khi nào | Field thêm |
| --- | --- | --- |
| `load_changed` (mở rộng) | Output đổi | `source`: `mqtt` \| `timer` \| `schedule` \| `cycle` \| `sensor` \| `disable` \| `interlock` \| `estop` \| `button` \| `boot` |
| `cycle_ended` | Cycle hoàn tất hoặc bị hủy | `load_id`, `reason`: `completed` \| `superseded` \| `manual` \| `disabled` \| `interlock` \| `estop` \| `all_off` |
| `emergency_stop` | E-STOP kích hoạt | `source`: `mqtt` \| `button` |
| `emergency_released` | E-STOP được thả | — |

`config_changed` (`kind:"load_control"`) đã có, mang `load_id` và `enabled`.

### 8.5 Bảng ánh xạ lệnh → hành vi

| Lệnh | `enabled=false` | E-STOP | Interlock tripped |
| --- | --- | --- | --- |
| `SET_STATE` | `forbidden` | `emergency_active` | `interlock_active` |
| `SET_LOAD_CYCLE` | `forbidden` | `emergency_active` | `interlock_active` |
| ` ` | `ok` | `ok` | `ok` |
| `EMERGENCY_STOP` | `ok` | `ok` (`changed:false`) | `ok` |
| `EMERGENCY_RELEASE` | `ok` | `ok` | `ok` |
| `config/set load_control` | chấp nhận | chấp nhận | chấp nhận |
| `GET_STATUS` | `ok` | `ok` | `ok` |

---

## 9. Logic task `load_control_task` (Core 1, priority 7, stack 3072; kiểm tra lại watermark)

### 9.1 Vòng lặp

```text
for (;;) {
    esp_task_wdt_reset();
    msg = xQueueReceive(load_cmd_queue, 100 ms);     // chu kỳ vòng <= 100 ms
    if (msg) handle_command(msg);
    now_us = esp_timer_get_time();
    for each load i:
        check_auto_off(i, now_us);
        check_cycle_deadline(i, now_us);              // chuyển WAIT_FIRST -> WAIT_SECOND -> IDLE
    if (time_valid && new_minute()) evaluate_schedule_all();   // 6.4.3
    check_interlock();
}
```

### 9.2 `handle_command`

```text
EMERGENCY_STOP / RELEASE   -> xử lý bằng API đồng bộ (6.2 LC-ES-02); nhánh queue chỉ dự phòng
                 -> mọi tải LOW, hủy timer, ACK ok            (không cần enabled)
SET_STATE / TIMED_CYCLE    -> kiểm tra theo thứ tự:
                              1. E-STOP?        -> emergency_active
                              2. enabled?       -> forbidden
                              3. interlock?     -> interlock_active
                              4. validate miền  -> invalid_*
                              5. thực hiện, đọc lại output thật, ACK
```

### 9.3 `apply_policy` (consumer của `config_cmd_queue` → `load_control_task`)

```text
nếu enabled=false:
    GPIO LOW trước; hủy cycle/auto_off; chuẩn hóa schedule; sau đó mới ghi NVS (LC-EN-03)
nếu enabled=true hoặc đổi lịch:
    bản sao tạm -> validate -> ghi NVS -> thành công thì áp vào RAM (mutex), lỗi thì giữ cũ
mọi trường hợp: dùng mutex bảo vệ app_config_t, không giữ mutex khi ghi NVS
```

### 9.4 Quy tắc hiện thực

- Không cấp phát động trong vòng lặp; mọi phần tử queue là struct giá trị.
- Không dùng callback software timer cho cycle/lịch; so sánh deadline trong vòng lặp để tránh race giữa timer service task và `load_control_task`. (Sửa mô tả "Software Timers cho từng tải" ở `requirements.md` mục 3.5 cho khớp, hoặc ghi lý do chọn khác trong `pipline.md`.)
- NVS commit chạy ở consumer `config_cmd_queue`, **không** chạy trong `load_control_task`.
- Mọi thay đổi output đi qua **một** hàm `load_set_output(i, level, source)` để đảm bảo phát `load_changed` và cập nhật LED_LOAD.

---

## 10. Yêu cầu cho Mobile App

Mã nguồn app không nằm trong workspace MCU; team app áp dụng đúng tên field, enum, UTC và bitmask của tài liệu này và `json_payoad.md`.

### 10.1 Màn hình tải (theo `load_control.jpg`)

| Phần tử UI | Nguồn / hành vi |
| --- | --- |
| Tiêu đề "Load 1 · Bơm nước", biểu tượng sửa | `name`; sửa tên gửi `config/set` `type=load_name` |
| "Trạng thái thực tế: BẬT" | `state` từ snapshot/`load_changed`; **không** lấy từ `enabled` hoặc từ yêu cầu vừa gửi |
| Switch "Cho phép" | `enabled`; gửi ngay khi gạt (mục 10.2) |
| BẬT / TẮT | `ON_THEN_OFF` / `OFF_THEN_ON` |
| "Thời gian bật" (hoặc "Thời gian tắt" khi chọn TẮT) | `on_delay_min` / `off_delay_min`, phút, 0..1440; 0 = thực hiện ngay |
| "Thời gian tắt kể từ khi bật" (hoặc "bật lại kể từ khi tắt") | `duration`, phút, 0..1440; 0 = không đổi lần hai |
| Nút "Gửi yêu cầu …" | Gửi `SET_LOAD_CYCLE` (hoặc `SET_STATE` nếu cả hai = 0) |
| Mục "Lịch hẹn": Giờ bật, Giờ tắt, "Áp dụng lịch hẹn" | `config/set` `type=load_control` |
| Mục "Điều kiện cảm biến": bật/tắt rule ON/OFF, chọn sensor ID, toán tử và ngưỡng | `config/set` `type=load_control`; tắt hẳn lịch tuần khi áp dụng rule |

### 10.2 Hành vi bắt buộc

| ID | Yêu cầu |
| --- | --- |
| APP-01 | Gạt switch "Cho phép" **gửi ngay** `config/set` `type=load_control` full-replace với toàn bộ field từ snapshot mới nhất; khi disable gửi hai cờ điều kiện=false. Không có nút xác nhận. |
| APP-02 | Trong lúc chờ ACK (tối đa 5 s) khóa switch của tải đó. ACK lỗi hoặc quá hạn ⇒ hoàn lại vị trí switch, báo lỗi, gửi `GET_STATUS` để đồng bộ. |
| APP-03 | Gửi config của cùng một tải **tuần tự**; sau mỗi ACK đọc lại snapshot rồi mới gửi tiếp (G-L8). Không dùng dữ liệu cũ để ghi đè. |
| APP-04 | Disable một tải đang có lịch: hiển thị cảnh báo "Lịch sẽ bị xóa" (D-L05). |
| APP-05 | Khi `enabled=false`: vô hiệu hóa khối "Yêu cầu điều khiển mới" và khối "Lịch hẹn", hiển thị lý do. Khi E-STOP: vô hiệu hóa tất cả điều khiển tải, hiển thị banner. |
| APP-06 | Sau khi gửi `SET_LOAD_CYCLE` thành công, **reset hai ô** về 0 và hiển thị đếm ngược từ `remaining_s` (kèm `cycle_next`). Khi nhận `cycle_ended`, xóa đếm ngược. |
| APP-07 | Nhãn nút phản ánh ý nghĩa: ví dụ "Bật sau 60 phút" hoặc "Bật ngay" (delay 0), thay cho "Gửi yêu cầu BẬT · 60 phút" nhập nhằng giữa delay và duration. |
| APP-08 | Validate trước khi gửi: integer 0..1440, không âm, không thập phân. |
| APP-09 | Dùng `(load_id)` 1-based, không dùng `interface_index` 0-based. Mỗi lệnh có `cmd_id` mới (UUID); lệnh thử lại sau `busy` dùng `cmd_id` mới; **thử lại E-STOP dùng cùng `cmd_id`**. |
| APP-10 | Khi thiết bị `presence: offline`, vô hiệu hóa gửi lệnh và hiển thị trạng thái cuối kèm thời điểm. |
| APP-11 | Đồng bộ nhiều app cùng `user_id` bằng `load_changed`, `cycle_ended`, `config_changed`, `emergency_*`. |
| APP-12 | Lịch tuần và điều kiện sensor loại trừ nhau; UI phải tắt/ẩn mode còn lại trước khi lưu. Hiển thị threshold theo đúng đơn vị của sensor; dùng `sensor_id` từ telemetry/snapshot. |

### 10.3 Bổ sung cho mục "Lịch hẹn"

- Thêm bộ chọn 7 ngày (T2…CN) và công tắc `schedule_enabled`.
- Chặn "Áp dụng" khi bật lịch mà chưa chọn ngày.
- Hiển thị giờ theo múi giờ điện thoại, gửi UTC.
- Khi nhận snapshot, đổi UTC ngược sang giờ địa phương **và** xoay `days_mask` ngược lại.

### 10.4 Chuyển đổi giờ

```text
offset_min = múi giờ điện thoại tại thời điểm gửi (phút so với UTC, ví dụ +420)
cho mỗi ngày địa phương d được chọn, giờ bật địa phương on_local (phút trong ngày):
    on_utc_abs = d*1440 + on_local - offset_min
    utc_day    = floor(on_utc_abs / 1440) mod 7        // bit cần đặt
    on_utc     = on_utc_abs mod 1440
off_utc = (off_local - offset_min) mod 1440
```

Nếu offset của điện thoại đổi (ví dụ chuyển múi giờ hoặc DST), app phải nhắc người dùng gửi lại lịch vì thiết bị chỉ biết UTC.

### 10.5 Nút tắt khẩn cấp

- Nút luôn hiển thị trên màn hình danh sách thiết bị và màn hình tải; giữ 1 giây để kích hoạt (D-L11).
- Gửi `EMERGENCY_STOP`; chưa nhận ACK thì thử lại cùng `cmd_id`.
- Khi `emergency.active`, hiển thị banner cố định và nút "Mở khóa" (gửi `EMERGENCY_RELEASE` với `confirm:true`, cần xác nhận).
- Sau khi mở khóa, hiển thị rõ **tải vẫn tắt**.

---

## 11. Yêu cầu phi chức năng

| ID | Yêu cầu |
| --- | --- |
| NFR-01 | Disable → chân LOW ≤ 200 ms; E-STOP → chân LOW ≤ 100 ms (không tính mạng). |
| NFR-02 | Sai số bước cycle ≤ ±2 s trong 24 giờ. |
| NFR-03 | `load_control_task` vòng ≤ 100 ms, gọi `esp_task_wdt_reset()` mỗi vòng, đăng ký TWDT. |
| NFR-04 | Không cấp phát động ở trạng thái ổn định; không truyền con trỏ giữa task. |
| NFR-05 | Không ghi NVS khi cấu hình không đổi; ghi `estop` chỉ khi đổi trạng thái. |
| NFR-06 | Mọi chuỗi trong ACK/event là hằng của firmware, không lặp nguyên văn dữ liệu người dùng. |
| NFR-07 | ACK ≤ 512 B, event ≤ 1024 B, snapshot/status ≤ 5120 B (`requirement_mqtt.md` mục 8.1). |
| NFR-08 | Lịch/cycle dùng đồng hồ khác nhau (UTC `time()` cho lịch, `esp_timer` cho cycle); không trộn. |

---

## 12. Mã lỗi

| Tình huống | `code` |
| --- | --- |
| JSON hỏng | `invalid_json` |
| Thiếu field bắt buộc, sai kiểu, `days_mask=0` với `schedule_enabled=true`, thiếu `confirm` | `invalid_fields` |
| Ngoài miền (`load_id`, delay/duration, `days_mask` > 127, `HH:mm` sai, `mode` sai) | `invalid_value` |
| `action`/`type` lạ | `unsupported_action` |
| Tải `enabled=false` | `forbidden` |
| E-STOP đang chốt | `emergency_active` (mới) |
| Interlock đang trip | `interlock_active` |
| Queue đầy, đang áp config trước, rate limit | `busy` |
| Ghi NVS lỗi | `storage_error` |
| Lỗi nội bộ, consumer không phản hồi trong 5 s | `internal_error` |

---

## 13. Tiêu chí chấp nhận (mở rộng AC-07, thêm AC-08)

| Test ID | Hạng mục | Kịch bản | Điều kiện đạt |
| --- | --- | --- | --- |
| LC-T01 | Bật/tắt từ xa | `SET_STATE` bật rồi tắt tải 1 | Relay đổi đúng; ACK `load.state` đúng; có `load_changed` (`source:"mqtt"`) |
| LC-T02 | Cycle bật trễ có duration | `ON_THEN_OFF`, delay 10, duration 20 (dùng giá trị thu nhỏ khi test, ví dụ 1/2 phút) | Tải giữ nguyên lúc chờ, ON đúng sau delay, OFF đúng sau duration (±2 s); `remaining_s` giảm đúng; cuối cùng `cycle_ended: completed` và cặp giá trị về 0 |
| LC-T03 | Cycle duration=0 | `ON_THEN_OFF`, delay 1, duration 0 | Tải bật sau 1 phút và không tự tắt; cycle kết thúc ngay sau bước 1 |
| LC-T04 | Cycle tắt trễ | `OFF_THEN_ON`, delay 0, duration 2 | Tắt ngay, bật lại sau 2 phút; `duration=0` thì giữ OFF |
| LC-T05 | Cycle thay thế | Gửi cycle thứ hai khi cycle đầu đang chờ | Cycle đầu bị hủy (`superseded`), chỉ cycle sau chạy |
| LC-T06 | `SET_STATE` hủy cycle | Đang chờ cycle, gửi `SET_STATE` | Cycle bị hủy, tải theo lệnh mới |
| LC-T07 | Cycle độc lập SNTP | Ép SNTP nhảy giờ trong lúc cycle chạy | Thời điểm bước chuyển không đổi |
| LC-T08 | Miền cycle | delay/duration = -1, 1441, 1.5, thiếu `duration`, `mode` lạ | `invalid_value` / `invalid_fields` đúng mã, relay không đổi |
| LC-T09 | Cycle bị mất khi reboot | Reboot giữa lúc cycle chờ | Tải OFF, snapshot `cycle_mode:"none"` |
| LC-T10 | Lịch tuần chạy | Đặt lịch cho ngày hiện tại, bật sau 2 phút, tắt sau 4 phút | Relay bật/tắt đúng mốc (≤ 2 s); `load_changed source:"schedule"` |
| LC-T11 | Lịch qua nửa đêm | `on=23:00`, `off=06:00` | Tắt 06:00 ngày UTC kế tiếp, không tắt sớm |
| LC-T12 | `days_mask` | Chỉ chọn một ngày; chờ ngày khác | Chỉ chạy đúng ngày đã chọn; xoay mask UTC+7 (ví dụ 79) cho đúng ngày địa phương |
| LC-T13 | Lịch lưu NVM | Đặt lịch cho tải 1 và tải 2 khác nhau, reboot | Hai lịch được khôi phục đúng, độc lập |
| LC-T14 | Không phát bù | Reboot sau mốc BẬT nhưng trước mốc TẮT | Tải OFF sau boot (D-L04), mốc TẮT không gây lỗi |
| LC-T15 | Lịch chưa có giờ | Boot khi chưa có SNTP | Không bắn mốc; sau `BIT_TIME_VALID` chỉ bắn mốc từ phút hiện tại |
| LC-T16 | Chống bắn lặp | SNTP lùi 1 phút ngay sau mốc | Mốc không bắn lần hai |
| LC-T17 | Ưu tiên lệnh tay | Mốc lịch rơi vào lúc cycle đang chạy | Mốc bị bỏ, không hoãn |
| LC-T18 | Cửa sổ 24 giờ | `on == off`, hai ngày liên tiếp | Mốc trùng phút không làm relay nhả rồi hút |
| LC-T19 | Disable | Gạt "Cho phép" tắt khi tải ON, có cycle và lịch | Chân LOW ≤ 200 ms; cycle/lịch bị hủy; `SET_STATE`/`SET_LOAD_CYCLE` ⇒ `forbidden`; ` ` vẫn `ok`; reboot vẫn bị khóa |
| LC-T20 | Disable khi NVS lỗi | Mô phỏng lỗi ghi NVS khi disable | Tải vẫn LOW, `enabled=false` ở RAM, ACK `storage_error` |
| LC-T21 | Enable | Bật lại sau disable | Tải **không** tự bật; lịch vẫn tắt (D-L05); lệnh mới được chấp nhận |
| LC-T22 | App gửi ngay | Gạt switch trên app | Message `config/set` xuất hiện ngay; switch khóa đến khi ACK; lỗi thì hoàn lại |
| LC-T23 | Ghi đè đồng thời | Gạt switch và bấm "Áp dụng lịch hẹn" liên tiếp | Không mất cấu hình; app gửi tuần tự |
| LC-T24 | Interlock | Ngắt mạng > `safety_timeout_s` khi tải ON/có cycle | Tải LOW; cycle bị hủy; khi mạng về tải không tự bật; mốc lịch BẬT bị chặn (D-L03) |
| LC-T25 | Điều kiện bật | Cấu hình ON `sensor_001 lt 10`, sample hợp lệ 9.9 | Tải ON; `load_changed source:"sensor"`; cấu hình còn sau reboot |
| LC-T26 | Điều kiện tắt | Cấu hình OFF `sensor_001 gte 20`, sample hợp lệ 20 | Tải OFF; `load_changed source:"sensor"` |
| LC-T27 | Sensor invalid/unknown | Gửi sample lỗi, thiếu sensor hoặc NaN/Inf cho sensor được rule tham chiếu | Tải OFF; không kích hoạt ON |
| LC-T28 | Rule cùng khớp | ON và OFF cùng true trong một sample | OFF thắng |
| LC-T29 | Schedule-rule coexistence | Gửi cấu hình có `schedule_enabled=true` cùng rule sensor enabled | Parser và NVS chấp nhận; điều kiện được ưu tiên hơn lịch |
| LC-T30 | Override/an toàn | Cycle/auto-off đang chạy, Interlock hoặc E-STOP hoạt động | Lệnh tay suppress sensor rule; Interlock/E-STOP không cho bật; OFF vẫn an toàn theo policy |
| LC-T33 | Condition và schedule cùng bật | Bật rule cảm biến và lịch tuần trên cùng tải | Cấu hình được chấp nhận; rule có ưu tiên hơn lịch |
| LC-T34 | Lịch ON bị điều kiện chặn | Điều kiện đang khớp tại đúng phút lịch ON; tắt điều kiện sau phút đó | Lịch ON bị bỏ qua, không chạy bù sau khi điều kiện bị tắt |
| LC-T35 | Hẹn giờ trễ chặn tự động | Để mốc lịch và sample điều kiện xảy ra trong lúc hẹn giờ trễ chạy | Hẹn giờ trễ giữ quyền điều khiển; mốc lịch không chạy bù |
| LC-T36 | Điều khiển tay tắt tự động | Bật điều kiện và lịch, sau đó gửi `SET_STATE` | Output theo lệnh tay; các điều kiện và lịch đang bật bị tắt trong cấu hình |
| LC-T31 | Schema migration | Load config schema v2 có lịch | Lịch/quyền giữ nguyên; rule sensor mặc định disabled và schema v3 được ghi |
| AC-08a | E-STOP cơ bản | `EMERGENCY_STOP` khi 4 tải đang ON | 4 chân LOW ≤ 100 ms; ACK `kind=emergency`; thu thập cảm biến dừng; `sensors[]` `valid:false,error:"stopped"`; không có LED lỗi Modbus; snapshot `emergency.active:true` |
| AC-08b | E-STOP không bị chặn | Gửi E-STOP khi `load_cmd_queue` đầy, tải `enabled=false`, chưa có giờ, lệnh có `ts` quá cũ | Vẫn thực hiện thành công |
| AC-08c | E-STOP chặn lệnh bật | Sau E-STOP gửi `SET_STATE`/`SET_LOAD_CYCLE`, để mốc lịch đến | `emergency_active`; mốc lịch không bật tải |
| AC-08d | E-STOP qua reboot | Reboot khi đang chốt | Tải LOW, không thu thập, MQTT online, release được |
| AC-08e | E-STOP idempotent | Gửi lại cùng `cmd_id` và `cmd_id` mới | `ok`, `changed:false`, không lỗi |
| AC-08f | Release | `EMERGENCY_RELEASE` thiếu và có `confirm:true` | Thiếu ⇒ `invalid_fields`; có ⇒ thu thập chạy lại, **tải vẫn OFF**, lịch chạy từ mốc kế tiếp |
| AC-08g | Factory reset | Giữ 6 s, nhả, giữ lại 5 s trong 2 s khi đang E-STOP | Trạng thái E-STOP bị xóa cùng NVS |
| LC-T32 | Đồng bộ nhiều app | Hai app cùng `user_id`; app A đổi tải | App B nhận `load_changed`/`config_changed` và cập nhật UI |

---

## 14. File phải đồng bộ và thứ tự hiện thực

### 14.1 File cần sửa/tạo

| File | Việc |
| --- | --- |
| `json_payoad.md` | Thêm `EMERGENCY_STOP/RELEASE`, ACK `kind=emergency`, field snapshot, sensor-condition config/snapshot |
| `requirement_mqtt.md` | Thêm action mới ở 8.2.1, `emergency_active` ở 8.3.2, event/`error:"stopped"` ở 8.4–8.5.3, `load_changed.source` mở rộng |
| `requirements.md` | Sửa 3.5 (timer), thêm E-STOP vào 3.5/6.2, mở rộng AC-07, thêm AC-08, bổ sung D-L* vào mục 13 |
| `main/main_data_types.h` | Shared sensor-condition types and NVS config schema v3 |
| `components/app_control` | **Tạo mới** (P5): `app_control.h/.c` theo mục 6, 7.4, 9 |
| `components/app_nvm` | Key `estop`, API get/set |
| `components/app_mqtt` | Parse full-replace conditions, route sensor samples, serialize sensor IDs and snapshot |
| `components/app_modbus` | `app_modbus_suspend()/resume()`; không set `SYS_ERR_MODBUS_TIMEOUT` khi suspended |
| `components/app_sysmon` | `BIT_SYS_ESTOP`, LED theo D-L13 |
| `pipline.md` | Active Work P5, Blocking Decisions D-L03/D-L07/D-L10 |
| Mobile App | Mục 10 |

### 14.2 Thứ tự đề xuất

1. Chốt D-L03, D-L07, D-L10 (không chặn các bước còn lại, đã có mặc định).
2. Cập nhật contract: `json_payoad.md`, `requirement_mqtt.md`, `main_data_types.h`.
3. `app_control`: GPIO an toàn → `SET_STATE`/` ` → enable/disable → cycle → lịch tuần → E-STOP → interlock chuyển quyền sở hữu.
4. `app_modbus` suspend/resume và `app_nvm` key `estop`.
5. Parser và ACK/event/snapshot trong `app_mqtt`.
6. Mobile App theo mục 10.
7. Chạy ma trận mục 13 trên board; chỉ đánh dấu P5 hoàn thành khi có bằng chứng.

---

## 15. Rủi ro

| # | Rủi ro | Giảm thiểu |
| --- | --- | --- |
| R-L1 | Trạng thái an toàn "tất cả OFF" có thể **nguy hiểm** với một số tải (máy sục khí/oxy) khi E-STOP, disable hoặc interlock trong ao nuôi | Xác nhận với chủ dự án (D-26 của `requirement_mqtt.md`); cân nhắc cờ "tải sống còn" ở bản sau |
| R-L2 | E-STOP qua MQTT phụ thuộc mạng/broker; broker công cộng dev không bảo đảm | Production dùng broker TLS riêng; cân nhắc nút E-STOP vật lý (LC-ES-12) |
| R-L3 | Mọi app cùng `user_id` đều gửi được E-STOP/RELEASE; chưa có xác thực nguồn lệnh ngoài ACL broker | D-21 của `requirement_mqtt.md` |
| R-L4 | Lịch tuần lệch ngày do đổi múi giờ sai | Mục 6.4.5, 10.4 và test LC-T12 |
| R-L5 | Relay hút/nhả nhanh khi lệnh dồn dập làm hỏng thiết bị | Cân nhắc thời gian tối thiểu giữa hai lần đổi trạng thái (chưa có trong spec) |
| R-L6 | Mất cycle/lịch sau mất điện khiến tải ngừng không báo trước | D-L04; app hiển thị rõ cycle không bền |
| R-L7 | `schedule` và `interlock` mâu thuẫn mục đích (G-L4) | D-L03 |
