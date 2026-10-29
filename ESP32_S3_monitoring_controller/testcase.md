# Test cases — Network Manager, interface switching và failover

## 1. Mục tiêu

Kiểm tra khởi tạo mạng, lựa chọn Ethernet/Wi-Fi, cô lập WAN probe theo từng interface, failover/failback, xử lý mất broker, mất cả hai đường truyền và độ ổn định sau nhiều lần chuyển mạng.

## 2. Thiết bị và điều kiện chuẩn bị

- ESP32-S3 với firmware cần kiểm thử, W5500 và dây Ethernet.
- Một Wi-Fi AP có Internet; cấu hình SSID/mật khẩu hợp lệ đã lưu trên thiết bị.
- Một Ethernet router/switch có DHCP và Internet.
- MQTT broker đang hoạt động, quyền subscribe tới topic `telemetry`, `status` và presence của thiết bị.
- Máy tính nối serial để thu log firmware; đồng bộ thời gian giữa máy tính và log nếu cần đo SLA.
- Có khả năng độc lập:
  - Rút/cắm cáp Ethernet.
  - Chặn WAN/ICMP trên một interface nhưng vẫn giữ link và địa chỉ IP.
  - Chặn riêng kết nối TCP tới MQTT broker.
  - Ngắt DHCP lease hoặc tắt từng AP/router.
- Trước các phép thử WAN, xác nhận mạng cho phép ICMP tới ít nhất một trong hai đích probe mặc định `1.1.1.1` và `8.8.8.8`. Nếu mạng chặn ICMP, kết quả WAN probe không đại diện chính xác cho khả năng truy cập Internet.

## 3. Quan sát và quy tắc đánh giá

1. Thu log serial liên tục, đặc biệt các dòng `WAN probe`, `active interface`, trạng thái FSM, MQTT connect/disconnect và lỗi W5500.
2. Ghi lại MQTT client connection, telemetry/status nhận được và trường `net_interface`.
3. Ghi thời điểm bắt đầu kích hoạt lỗi mạng và thời điểm MQTT kết nối lại trên interface mới.
4. Cấu hình mặc định trong firmware/spec:
   - Probe gồm 2 đích; mỗi đích tối đa 3 ping, timeout/interval 1 giây. Có ít nhất một reply thì interface được xem là WAN OK.
   - Active ổn định, standby và recovery: probe mỗi 1 giây.
   - Ethernet failback khi Wi-Fi active: probe mỗi 1 giây, cần 5 lần OK liên tiếp (xấp xỉ 5 giây).
   - Không chuyển interface chỉ vì broker MQTT mất kết nối nếu WAN probe vẫn OK.
   - Ethernet là interface được ưu tiên khi Ethernet và Wi-Fi đều có WAN.
5. Với mỗi test, điền kết quả thực tế:

| Test ID | Pass/Fail | Kết quả thực tế / log tham chiếu | Người chạy / ngày |
|---|---|---|---|
| | | | |

## 4. Test cases

### NWM-BOOT-01 — Ma trận khởi động interface

**Bước thực hiện**

1. Lần lượt chuẩn bị bốn trạng thái khởi động:
   - A. NVS chưa có cấu hình mạng, không cắm Ethernet.
   - B. NVS chưa có cấu hình mạng, có cắm Ethernet và Ethernet nhận IP.
   - C. Có Wi-Fi credentials hợp lệ, không cắm Ethernet.
   - D. Có Wi-Fi credentials hợp lệ, Ethernet cắm và nhận IP.
2. Reboot thiết bị ở mỗi trạng thái; quan sát serial, LED, MQTT và các topic.

**Expected**

- A: vào BLE provisioning; không giả báo interface active.
- B: firmware hiện cũng vào BLE provisioning vì chưa có cấu hình mạng hợp lệ. Sau khi provisioning thành công, tiếp tục network connecting; không coi riêng việc cắm cáp là cấu hình provisioned.
- C: thử Wi-Fi; sau khi có IP/WAN OK, chọn Wi-Fi và khởi động MQTT.
- D: khi cả hai interface đều có WAN, Ethernet được chọn làm active.
- Không trường hợp nào reboot lặp hoặc kích hoạt WDT trong quá trình khởi tạo.

### NWM-SEL-01 — Ethernet được ưu tiên khi cả hai interface đều sẵn sàng

**Bước thực hiện**

1. Lưu Wi-Fi credentials hợp lệ.
2. Cắm Ethernet và bảo đảm cả Wi-Fi lẫn Ethernet đều có IP và ping được WAN.
3. Khởi động lại thiết bị; theo dõi các probe và route/default interface.

**Expected**

- Probe của ETH và Wi-Fi được ghim vào đúng interface.
- Active/default interface cuối cùng là Ethernet (`ETH`); telemetry báo `net_interface: "ETH"`.
- MQTT chỉ khởi động trên route active, không có routing loop hoặc reconnect storm.

### NWM-PROV-01 — Runtime provisioning từ Ethernet-only sang Ethernet + Wi-Fi

**Bước thực hiện**

1. Provisioning lần đầu với `only_use_ethernet: true`, cùng tài khoản sẽ dùng ở các bước sau.
2. Giữ Ethernet có IP/WAN và xác nhận ETH active.
3. Mở runtime BLE provisioning, đổi sang `only_use_ethernet: false` với Wi-Fi hợp lệ.
4. Chờ app nhận kết quả và phiên BLE kết thúc; theo dõi ít nhất 3 chu kỳ WAN probe.
5. Rút cáp Ethernet, sau đó cắm lại và chờ failback.
6. Reboot để kiểm tra cấu hình được giữ lại.
7. Thử lại với Wi-Fi sai mật khẩu hoặc để phiên BLE hết hạn mà không gửi cấu hình.
8. Runtime provisioning về Ethernet-only, sau đó bật lại Ethernet + Wi-Fi.

**Expected**

- Cấu hình mới được nạp vào RAM trước khi kết thúc phiên provisioning; không tắt Wi-Fi
  do dùng lại cấu hình Ethernet-only cũ.
- ETH vẫn active khi cả hai đường có WAN; Wi-Fi giữ kết nối và được probe ở chế độ standby
  sau khi BLE kết thúc.
- Khi rút cáp, chuyển sang WIFI nếu WAN Wi-Fi OK và MQTT kết nối lại; ngoài các hiệu ứng
  đặc biệt, LED Ethernet tắt và LED Wi-Fi sáng.
- Khi cắm lại cáp và đủ số probe failback OK, chuyển về ETH; LED Wi-Fi tắt.
- Reboot vẫn dùng cấu hình Ethernet + Wi-Fi đã lưu.
- Sai mật khẩu hoặc phiên không gửi cấu hình không thay đổi cấu hình đã lưu trước đó.
- Chuyển về Ethernet-only tắt Wi-Fi; bật lại Wi-Fi trong phiên tiếp theo vẫn hoạt động.

### NWM-PROBE-01 — Phán quyết WAN theo số reply ICMP

**Bước thực hiện**

1. Cho ETH và Wi-Fi có link/IP.
2. Chặn ICMP tới một probe target trên ETH nhưng cho target còn lại phản hồi.
3. Lặp lại khi cả hai target đều không trả lời trên ETH, nhưng Wi-Fi vẫn có WAN.
4. Lặp lại phép thử tương tự trên Wi-Fi.

**Expected**

- Có ít nhất 1 reply từ các target trên interface được probe: verdict `OK`.
- Không có reply từ cả hai target sau các request: verdict `FAIL`.
- Ping gateway/L2 link đơn thuần không làm interface được xác nhận WAN OK.
- Việc probe standby không đổi default route và không tự ngắt MQTT trên active interface.

### NWM-FAIL-01 — Failover tức thời khi rút Ethernet đang active

**Bước thực hiện**

1. Đảm bảo ETH đang active; Wi-Fi có IP, WAN OK và đã được xác nhận standby-ready.
2. Duy trì telemetry/MQTT.
3. Rút cáp Ethernet; ghi thời điểm link-down, thời điểm chuyển interface và thời điểm MQTT kết nối lại.

**Expected**

- Mất link/IP active được xử lý ngay, không chờ chu kỳ ping.
- FSM vào failover, đổi default interface sang Wi-Fi, cập nhật DNS và khởi động lại MQTT socket.
- MQTT kết nối lại qua Wi-Fi trong **< 5 giây** từ lúc link-down.
- Telemetry trong thời gian gián đoạn được buffer; không mất thứ tự hoặc sinh lặp ngoài chính sách buffer.
- Hệ thống không reboot; tải không bị đổi trạng thái chỉ do failover.

### NWM-FAIL-02 — Failover khi Ethernet còn link/IP nhưng mất WAN âm thầm

**Bước thực hiện**

1. Đặt ETH active và Wi-Fi standby có WAN OK.
2. Giữ Ethernet link/IP; chặn WAN ICMP trên riêng đường ETH tới cả hai probe targets.
3. Để Wi-Fi tiếp tục truy cập được Internet.
4. Đo từ lần active probe thất bại tới khi MQTT kết nối lại qua Wi-Fi.

**Expected**

- ETH có thể vẫn báo link/IP, nhưng verdict WAN phải là `FAIL` khi cả hai probe targets không trả lời.
- FSM vào failover và chuyển sang Wi-Fi.
- MQTT kết nối lại qua Wi-Fi trong **≤ 10 giây** theo tiêu chí hiện hành.
- Telemetry báo `net_interface: "WIFI"` sau khi route mới hoạt động; thiết bị không reboot.

### NWM-FAIL-03 — Failover khi Wi-Fi đang active bị mất association/IP

**Bước thực hiện**

1. Làm cho Wi-Fi thành active (ví dụ ngắt WAN Ethernet để chuyển qua Wi-Fi, nhưng để Ethernet standby có WAN trở lại).
2. Tắt AP Wi-Fi hoặc làm mất association/DHCP lease của Wi-Fi.
3. Ghi thời điểm Wi-Fi link/IP mất và MQTT reconnect trên Ethernet.

**Expected**

- Mất association/IP trên active Wi-Fi kích hoạt failover ngay, không chờ WAN probe định kỳ.
- Nếu ETH có L3 và WAN OK, route đổi sang Ethernet và MQTT reconnect.
- Nếu ETH không sẵn sàng, chuyển vào `NET_LOST` theo NWM-LOST-01.

### NWM-FAIL-04 — Mất DHCP lease trên interface active

**Bước thực hiện**

1. Cho thiết bị hoạt động ổn định với ETH active và Wi-Fi standby-ready.
2. Xóa DHCP lease của thiết bị hoặc cấu hình router để thiết bị mất IP Ethernet trong khi cáp vẫn cắm.
3. Quan sát event/IP state, FSM và MQTT.

**Expected**

- Mất IP được xem như active link-down và kích hoạt failover tức thời.
- Wi-Fi được chọn nếu còn WAN OK; MQTT reconnect trên Wi-Fi.
- Interface không có IP không được xem là active/WAN-ready chỉ vì link vật lý vẫn lên.

### NWM-FAILBACK-01 — Failback về Ethernet có hysteresis

**Bước thực hiện**

1. Bắt đầu với Wi-Fi active và MQTT đang hoạt động.
2. Cắm lại Ethernet hoặc khôi phục Ethernet WAN; đảm bảo Ethernet có IP.
3. Theo dõi probe ETH và trạng thái `net_interface`.

**Expected**

- Không chuyển về Ethernet ngay khi vừa có link/IP.
- Ethernet phải đạt **5 probe WAN OK liên tiếp**, khoảng **5 giây** với chu kỳ 1 giây.
- Sau đủ 5 lần, route chuyển về ETH; MQTT restart qua interface mới.
- Wi-Fi vẫn giữ kết nối làm standby.

### NWM-FAILBACK-02 — Link/WAN Ethernet chập chờn không gây flapping

**Bước thực hiện**

1. Để Wi-Fi active và WAN ổn định.
2. Cắm/rút cáp ETH hoặc bật/tắt WAN Ethernet 5 lần, cách nhau khoảng 2 giây.
3. Sau đó khôi phục ETH liên tục và theo dõi thêm ít nhất 20 giây.

**Expected**

- Mỗi lần fail hoặc link-down ETH reset chuỗi failback OK.
- Không chuyển route qua lại liên tục; Wi-Fi tiếp tục làm active trong giai đoạn ETH chưa ổn định.
- Chỉ failback sau 5 probe ETH OK liên tiếp kể từ lần khôi phục ổn định cuối cùng.
- MQTT không có reconnect storm.

### NWM-FAULT-01 — MQTT broker mất nhưng WAN vẫn tốt

**Bước thực hiện**

1. Cho ETH active, Wi-Fi standby; xác nhận probe WAN đều OK.
2. Chặn riêng TCP tới MQTT broker, không chặn ICMP probe targets.
3. Quan sát ít nhất vài chu kỳ active probe và các lần MQTT reconnect.
4. Mở lại kết nối tới broker.

**Expected**

- Active interface không đổi; FSM không vào failover chỉ vì broker down.
- MQTT retry dùng backoff riêng, theo khoảng ngẫu nhiên có sàn 200 ms và trần 60 giây.
- Khi broker phục hồi, MQTT kết nối lại trên cùng interface; không phát sinh switch ETH/Wi-Fi.

### NWM-LOST-01 — Cả hai interface mất WAN và tự phục hồi

**Bước thực hiện**

1. Khởi động trong trạng thái ETH active và Wi-Fi có WAN.
2. Đồng thời chặn WAN cho cả hai interface (có thể giữ link/IP) hoặc tắt cả hai router.
3. Quan sát FSM, error mask, MQTT và telemetry.
4. Khôi phục WAN cho một interface.

**Expected**

- Khi active mất WAN và standby cũng không xác nhận được WAN, thiết bị vào `NET_LOST`; active interface là `NONE`, đặt `SYS_ERR_NET_LOST`, MQTT dừng.
- Hai interface được probe theo recovery period khoảng 1 giây.
- Khi một interface có WAN trở lại, FSM chọn interface đó, cập nhật route/DNS, MQTT reconnect và clear lỗi mạng.
- Không cần reboot hoặc thao tác người dùng để phục hồi mạng.

### NWM-SAFE-01 — Safety interlock sau khi mất toàn bộ mạng kéo dài

**Bước thực hiện**

1. Cho các relay/tải ở trạng thái ON và thiết bị vào hoạt động bình thường.
2. Làm mất WAN trên cả ETH và Wi-Fi, giữ tình trạng này quá 300 giây.
3. Quan sát relay output, `BIT_SYS_INTERLOCK_TRIPPED`/snapshot và trạng thái mạng.
4. Khôi phục WAN.

**Expected**

- Trước mốc 300 giây, trạng thái tải không tự thay đổi chỉ do mất mạng.
- Đủ 300 giây mất mạng, safety interlock đưa tất cả relay về OFF và latch interlock.
- Khi mạng trở lại, MQTT phục hồi nhưng relay vẫn OFF cho đến khi có lệnh điều khiển hợp lệ; không tự bật lại.

### NWM-BOOT-02 — Không có standby khi active bị mất

**Bước thực hiện**

1. Khởi động chỉ với một interface có WAN; interface còn lại tắt hoặc không có cấu hình.
2. Đợi interface đơn đó trở thành active.
3. Ngắt link/IP/WAN của active.

**Expected**

- Không cố chuyển sang interface không có IP/WAN.
- Hệ thống vào `NET_LOST`, active là `NONE`, đặt lỗi mạng và dừng MQTT.
- Khi interface có WAN trở lại, tự kết nối lại theo NWM-LOST-01.

### NWM-ETH-01 — W5500 không có mặt lúc khởi động

**Bước thực hiện**

1. Có Wi-Fi credentials hợp lệ; tháo W5500 hoặc không cấp nguồn/cáp cho module Ethernet.
2. Khởi động thiết bị và quan sát quá trình khởi tạo ETH, Wi-Fi và MQTT.
3. Sau khi Wi-Fi đã hoạt động, kết nối lại W5500/Ethernet.

**Expected**

- Lỗi khởi tạo W5500 không làm treo/reboot loop; Wi-Fi vẫn có thể trở thành active.
- Manager thử khởi tạo lại W5500 theo chu kỳ retry 5 giây.
- Khi ETH có link/IP/WAN, được probe và chỉ failback theo hysteresis 5 probe OK; không chuyển ngay.

### NWM-ETH-02 — Phục hồi phần cứng W5500 và giới hạn reset

**Bước thực hiện**

1. Để thiết bị chạy với Ethernet active hoặc Wi-Fi fallback.
2. Gây lỗi đọc `VERSIONR` của W5500 (theo quy trình bench an toàn, không làm hỏng board).
3. Tạo 3 lần đọc lỗi liên tiếp; sau khi phục hồi, kiểm tra link/DHCP/probe.
4. Trong môi trường bench, lặp lỗi vượt quá giới hạn reset mỗi giờ đã cấu hình.

**Expected**

- Sau ngưỡng lỗi phần cứng, firmware thực hiện quy trình hard reset/reinstall driver và ghi log trạng thái.
- Nếu phục hồi thành công, Ethernet lên lại và tuân theo chính sách failback.
- Không vượt quá ngân sách reset W5500 mỗi giờ; khi chạm giới hạn, hệ thống giữ Wi-Fi-only đến reboot.
- Không ảnh hưởng an toàn của relay hoặc làm treo task mạng.

### NWM-ROUTE-01 — Hai interface cùng subnet, probe phải cô lập

**Bước thực hiện**

1. Kết nối Ethernet và Wi-Fi vào cùng router/subnet.
2. Đảm bảo cả hai interface nhận IP.
3. Tạm chặn WAN trên một interface nhưng vẫn để interface kia truy cập được; xem log probe/interface và route.
4. Lặp lại bằng cách đảo interface bị chặn.

**Expected**

- Probe được ghim vào netif được kiểm tra, không đi nhầm qua default route.
- Khi cả hai WAN OK, ETH active.
- Khi WAN của active fail, chỉ chuyển nếu standby WAN OK.
- Không có routing loop, false-positive WAN do probe chạy qua interface còn lại, hoặc đổi default netif ngoài quyết định của FSM.

### NWM-MEM-01 — Lặp failover/failback 100 lần

**Bước thực hiện**

1. Đo baseline free heap và largest free block sau khi mạng/MQTT ổn định.
2. Tạo 100 chu kỳ chuyển ETH → Wi-Fi → ETH; bảo đảm mỗi lần switch có đủ thời gian hoàn tất.
3. Sau mỗi nhóm 10 chu kỳ, ghi heap, largest free block, số lần failover và lỗi WDT.

**Expected**

- Không rò rỉ ping session hoặc socket; tất cả session ping được giải phóng.
- Sau 100 chu kỳ, free heap giảm không quá **2 KB** so với baseline; largest free block không giảm bất thường.
- Không có WDT, crash, route sai hoặc MQTT reconnect storm.

### NWM-SOAK-01 — Soak test 24 giờ

**Bước thực hiện**

1. Chạy telemetry và MQTT liên tục với cả hai interface khả dụng.
2. Thực hiện tổng cộng 200 chu kỳ failover/failback phân bố trong 24 giờ; ghi lại thời điểm và interface active.
3. Ghi stack high-water mark, free heap, largest free block, failover count, MQTT reconnect count và WDT/reset log.

**Expected**

- Không crash/reboot ngoài chủ đích, không có WDT.
- `uxTaskGetStackHighWaterMark` của các task liên quan luôn **> 1024 bytes**.
- Không phân mảnh/rò rỉ heap đáng kể; manager tiếp tục chọn đúng interface và tự phục hồi sau mỗi lần mạng thay đổi.

## 5. Tiêu chí hoàn tất

- Tất cả test bắt buộc NWM-BOOT-01, NWM-SEL-01, NWM-FAIL-01..04, NWM-FAILBACK-01..02, NWM-FAULT-01 và NWM-LOST-01 đạt.
- Các test phần cứng W5500, memory leak và soak phải ghi rõ nếu chưa thể chạy; không đánh dấu Pass dựa trên mô phỏng.
- Đính kèm log serial, MQTT trace và số đo thời gian thực tế cho mọi test có SLA.
- Nếu kết quả khác expected, ghi lại firmware version, board/W5500 revision, sơ đồ mạng và bước tái hiện trước khi kết luận.
