<overview>
Người dùng muốn đọc source ESP32 và Flutter rồi phối hợp triển khai giao tiếp thực tế; các bất đồng về topic, endpoint, command phải được hỏi trước khi tự chọn. Đã lần lượt hỏi và nhận quyết định về MQTT topics, luồng điều khiển trực tiếp, mô hình cấu hình tải và cách chọn thiết bị; đã triển khai nền tảng protocol/ACK và nối một phần UI, đồng thời phát hiện thêm xung đột BLE provisioning chưa xử lý.
</overview>

<history>
1. Người dùng yêu cầu đọc source hai bên và bắt đầu làm cho ESP32–Flutter giao tiếp ổn định; khi contract xung đột thì phải hỏi.
   - Workspace gồm ESP-IDF project `ESP32_S3_monitoring_controller` và Flutter project `flutter_app`.
   - Đối chiếu source MQTT, BLE, Flutter service/UI và docs hiện có.

2. Đã hỏi về topic vì firmware và Flutter lệch:
   - Firmware dùng `v1/{user_id}/devices/{device_id}/...`, cấu hình ở `/config/set`.
   - Flutter cũ dùng `v1/users/{user_id}/devices/{device_id}/...`, cấu hình ở `/set`.
   - Người dùng chốt theo firmware; đã sửa builder, router, test và một phần tài liệu Flutter.

3. Đã hỏi về điều khiển/config:
   - Flutter đang dùng `CrudApi.afterAck()` và ACK giả; firmware không có HTTP/REST endpoint, chỉ nhận MQTT.
   - Firmware từ chối `new_name` trên command; đổi tên tải là config `type: "load_name"`.
   - Người dùng chọn thao tác thiết bị đi trực tiếp qua MQTT; CRUD/backend tách riêng, không được coi là ACK thiết bị.
   - Đã bỏ ACK giả, thêm encode payload và MQTT ACK correlation, nối màn hình cảm biến/tải với publish MQTT.

4. Đã hỏi về khả năng cấu hình tải:
   - Firmware hỗ trợ một cấu hình full-replace mỗi tải; lịch tuần không thể đồng thời bật cùng rule cảm biến.
   - Flutter mock cũ có nhiều lịch/điều kiện dạng CRUD.
   - Người dùng chọn chỉnh UI theo contract firmware: một cấu hình mỗi tải, lịch tuần **hoặc** rule cảm biến, đồng thời gửi lệnh tay/chu kỳ qua MQTT.
   - Đã thay màn hình điều khiển tải mock cũ bằng UI lệnh `SET_STATE`, `SET_LOAD_CYCLE`, rename qua config, và cấu hình lịch/rule.

5. Đã hỏi về chọn thiết bị vì session MQTT hỗ trợ nhiều device nhưng UI chưa truyền device ID.
   - Người dùng chọn bắt buộc chọn thiết bị từ Device List rồi truyền ID qua Dashboard và màn hình con.
   - Đã thêm model chọn thiết bị, danh sách thiết bị lấy từ MQTT session local, và truyền lựa chọn qua các route liên quan.

6. Khi rà tiếp BLE provisioning, phát hiện một contract mismatch nghiêm trọng nhưng chưa hỏi/chưa sửa:
   - Firmware yêu cầu đúng 4 field: `ssid`, `password`, `user_id`, `only_use_ethernet`; trả `IN_PROGRESS` khi nhận cấu hình.
   - Flutter hiện gửi `wifi_ssid`, `wifi_pass`, `user_id` và chỉ chấp nhận `SUCCESS` ngay lập tức.
   - Firmware có `prov-status` để poll trạng thái (`idle`/`in_progress`/`done`) và trả kết quả cuối cùng.
   - Đây là điểm đang dở; cần hỏi người dùng/chốt đồng bộ trước khi sửa BLE.
</history>

<work_done>
Files tạo mới:
- [mqtt_ack.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/protocol/mqtt_ack.dart>) — parser/model cho ACK firmware.
- [mqtt_payloads.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/protocol/mqtt_payloads.dart>) — tạo `cmd_id` UUID v4, payload lệnh/config và validation.
- [device_selection.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/models/device_selection.dart>) — chọn device và context cấu hình sensor.
- [load_control_selection.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/models/load_control_selection.dart>) — truyền device + load vào màn hình điều khiển.
- [mqtt_payloads_test.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/test/mqtt_payloads_test.dart>) — test payload/ACK.

Files sửa:
- [mqtt_topics.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/protocol/mqtt_topics.dart>) — topic firmware chuẩn, `config/set`, validate user/device ID và route topic con.
- [mqtt_session_manager.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/services/mqtt_session_manager.dart>) — publish config đúng topic, chờ ACK theo device + `cmd_id`, timeout mặc định 10 giây; lưu tên device local.
- [mqtt_topics_test.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/test/mqtt_topics_test.dart>) — topic/router tests theo contract firmware.
- [device_list_screen.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/screens/device_list_screen.dart>) — danh sách device từ session thay vì ba device demo tĩnh; chọn device để mở Dashboard.
- [dashboard_screen.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/screens/dashboard_screen.dart>) — nhận DeviceSelection, truyền tiếp vào các màn hình, E-STOP qua MQTT và lệnh bật/tắt chờ ACK.
- [load_control_screen.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/screens/load_control_screen.dart>) — thay mock CRUD nhiều lịch/rule bằng lệnh và config MQTT theo firmware.
- [sensor_config_screen.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/screens/sensor_config_screen.dart>) — publish cấu hình sensor thật với `interface_type`, `interface_index`, `sensor_type`, rồi chờ ACK.
- [sensor_capacity_screen.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/screens/sensor_capacity_screen.dart>), [app_routes.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/navigation/app_routes.dart>), [provision_success_screen.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/screens/provision_success_screen.dart>) — truyền/lưu device selection và ID.
- [crud_api.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/services/crud_api.dart>) — bỏ `EspAck` giả và `afterAck`; CRUD còn là backend stub, không còn giả ACK thiết bị.
- [console_screen.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/screens/console_screen.dart>) — sửa mẫu topic/payload cho khớp contract.
- [requirement.md](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/docs/requirement.md>) — cập nhật topic/Q1.
- [plan.md](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/docs/plan.md>) — đổi mô tả topic cấu hình sang `config/set`.
- [widget_test.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/test/widget_test.dart>) — thay tests phù hợp UI mới.

Xác minh:
- `flutter analyze`: **pass**, không có issue.
- `flutter test test/widget_test.dart`: **pass**, 6 tests.
- Toàn bộ `flutter test` đã chạy trước khi sửa test scroll; khi đó chỉ fail một widget test do thao tác với control ngoài viewport. Test đó đã sửa và chạy riêng pass, nhưng **chưa chạy lại toàn bộ suite sau sửa**.
- `flutter test test/mqtt_topics_test.dart` pass trước đó; topic/payload tests cũng đã qua trong lần chạy suite có một failure widget.
- Chưa test MQTT broker thật hoặc thiết bị ESP32 thật; trạng thái/telemetry dashboard vẫn còn mock, chưa có store/parser hoàn chỉnh.
</work_done>

<technical_details>
- Firmware MQTT thật tạo topic `v1/{user_id}/devices/{device_id}/{telemetry,commands,ack,config/set,status}`; device ID là 12 ký tự hex thường của Wi-Fi STA MAC. Flutter builder nay enforce format này.
- Firmware parser bắt buộc `cmd_id` hợp lệ (1–36 ký tự `[A-Za-z0-9_-]`); `v:1` được gửi theo contract.
- ACK firmware có `cmd_id`, `kind`, `result` (`ok`/`error`), `code`, có thể có `reason`; success là `result == "ok"` và `code == "ok"`.
- Lệnh trực tiếp dùng `SET_STATE` và `SET_LOAD_CYCLE`; command không được có `new_name`.
- Sensor config dùng `type:"sensor"` và bắt buộc interface identity; RS485 index 0-based, sensor type `sht40`/`do`/`ph`, slave ID 1–247. Analog dùng `interface_type:"analog_4_20ma"` và slot 0.
- Rename tải là config `type:"load_name"` trên `/config/set`.
- Load policy là full-replace; `schedule_enabled` không thể cùng bật sensor rules; ngày bit 0 = Monday; firmware cần `on_time_utc`/`off_time_utc`. Flutter UI chuyển giờ local sang UTC khi tạo lịch và báo lỗi nếu các ngày chọn ánh xạ sang nhiều UTC clock khác nhau.
- `SET_STATE` Flutter gửi `duration_min`; firmware cũng hỗ trợ `duration_sec` tương thích cũ nhưng không gửi đồng thời.
- MqttSessionManager subscribe telemetry QoS 0 và ACK/status QoS 1, còn publish command/config QoS 1.
- BLE mismatch còn mở: firmware yêu cầu field JSON và trạng thái asynchronous như phần lịch sử. Cần xử lý bằng poll `prov-status` sau `IN_PROGRESS`; hiện Flutter báo lỗi nếu chưa nhận `SUCCESS` trực tiếp.
- Repo/workspace không phải Git repo. Không chạy build ESP-IDF hay test phần cứng.
</technical_details>

<important_files>
- [app_mqtt_proto.c](<C:/Users/hoang/OneDrive/Desktop/Farming Project/ESP32_S3_monitoring_controller/components/app_mqtt/app_mqtt_proto.c>) — source-of-truth đang chạy cho topic builder, parser lệnh/config, ACK serializer.
- [requirement_mqtt.md](<C:/Users/hoang/OneDrive/Desktop/Farming Project/ESP32_S3_monitoring_controller/requirement_mqtt.md>) — contract firmware MQTT; các ví dụ và giới hạn load policy.
- [app_ble_prov.c](<C:/Users/hoang/OneDrive/Desktop/Farming Project/ESP32_S3_monitoring_controller/components/app_ble_prov/app_ble_prov.c>) — contract provisioning firmware; field `ssid/password/user_id/only_use_ethernet`, `IN_PROGRESS`, `prov-status`.
- [app_ble_prov.h](<C:/Users/hoang/OneDrive/Desktop/Farming Project/ESP32_S3_monitoring_controller/components/app_ble_prov/include/app_ble_prov.h>) — mô tả BLE endpoints và PoP.
- [ble_prov_service.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/services/ble_prov_service.dart>) — Flutter hiện vẫn gửi `wifi_ssid/wifi_pass/user_id` và đòi `SUCCESS`.
- [mqtt_session_manager.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/services/mqtt_session_manager.dart>) — connection/subscription/publish và ACK waiter.
- [mqtt_payloads.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/protocol/mqtt_payloads.dart>) — protocol payload encoders/validation.
- [load_control_screen.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/screens/load_control_screen.dart>) và [sensor_config_screen.dart](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/lib/screens/sensor_config_screen.dart>) — màn hình thao tác thiết bị trực tiếp.
- [requirement.md](<C:/Users/hoang/OneDrive/Desktop/Farming Project/flutter_app/docs/requirement.md>) — mới chỉ cập nhật topic; các schema BLE/lệnh cũ cần sửa tiếp.
</important_files>

<next_steps>
1. **Hỏi người dùng** về xung đột BLE provisioning: có đồng bộ Flutter theo firmware (`ssid`, `password`, `user_id`, `only_use_ethernet`; xử lý response `IN_PROGRESS` rồi poll `prov-status`) không? Không tự sửa trước khi chốt vì user yêu cầu hỏi các contract xung đột.
2. Sau khi được chốt, sửa BLE request/response flow, truyền `device_id` cuối cùng từ `prov-status` vào đăng ký session và kiểm thử; kiểm tra Ethernet-only cũng gửi đủ bốn field.
3. Cập nhật Flutter requirement/plan/pipeline cho các contract đã chốt (topic, ACK, 4 loads, `duration_min`, rename qua `load_name`, BLE), vì docs Flutter còn nhiều schema cũ.
4. Sửa `CrudApi.addDevice`/các backend stub sao cho rõ ràng đây là backend-only, không trì hoãn/giả lập ACK thiết bị.
5. Chạy lại `flutter analyze` và toàn bộ `flutter test`; sau đó cần test integration với broker/ESP32 thật.
6. Tiếp tục state store và parse status/telemetry; dashboard hiện chưa lấy trạng thái thực từ ESP.
</next_steps>