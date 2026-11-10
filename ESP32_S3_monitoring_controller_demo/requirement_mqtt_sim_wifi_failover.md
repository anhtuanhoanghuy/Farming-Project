# Requirement kết nối MQTT qua Wi-Fi và SIM 4G (bản demo)

## 1. Mục tiêu

Thiết bị demo ESP32-S3 hỗ trợ kết nối MQTT qua Wi-Fi hoặc qua mạng di động 4G bằng module SIMCom A7680C. Firmware phải quản lý chuyển đổi kết nối khi đường truyền đang dùng mất kết nối và cung cấp lựa chọn chế độ mạng trong ứng dụng.

Phạm vi tài liệu này là yêu cầu chức năng cho bản demo; không thay thế yêu cầu vận hành, bảo mật hoặc chứng nhận của sản phẩm thương mại.

## 2. Phạm vi phần cứng và giao tiếp

- Module 4G: SIMCom A7680C.
- Giao tiếp điều khiển modem: UART0 của ESP32-S3.
- Firmware chịu trách nhiệm khởi tạo UART, gửi/nhận AT command, kiểm tra trạng thái SIM, đăng ký mạng di động, thiết lập PDP context và lấy trạng thái kết nối/IP.
- MQTT dùng cùng broker, thông tin xác thực, topic, payload và QoS hiện có của thiết bị; thay đổi đường truyền không được làm thay đổi giao thức ứng dụng.
- UART0: ESP32-S3 TX GPIO43 → modem RX, ESP32-S3 RX GPIO44 ← modem TX, baud rate 115200. RESET_N nối GPIO1 (active-low); DTR nối GPIO2 và giữ ở mức hoạt động.
- APN phải cấu hình theo SIM/nhà mạng; broker, thông tin xác thực và timeout lấy theo cấu hình hiện có, không hard-code thông tin nhạy cảm vào mã nguồn.

## 3. Chế độ mạng do ứng dụng lựa chọn

Ứng dụng phải cho phép người dùng chọn và gửi một trong hai chế độ sau:

| Chế độ | Hành vi bắt buộc |
|---|---|
| Tự động (Wi-Fi ưu tiên) | Dùng Wi-Fi khi Wi-Fi có Internet; chuyển sang 4G khi Wi-Fi mất Internet; tự chuyển lại Wi-Fi sau khi Wi-Fi phục hồi ổn định. |
| Chỉ 4G | Chỉ dùng A7680C/4G. Wi-Fi không được dùng làm đường truyền MQTT hoặc làm đường dự phòng. Nếu 4G không khả dụng, báo mất kết nối và thử kết nối lại 4G. |

- Chế độ được lưu bền vững trên thiết bị và được khôi phục sau khi reset thiết bị (cả hard reset và soft reset). Cái này tương tự như ethernet thôi mà.
- Chế độ “Chỉ 4G” là yêu cầu riêng: không được failover sang Wi-Fi trong bất kỳ trường hợp nào. Việc mất 4G không tự động đổi chế độ đã chọn. Cái này tương tự như ethernet thôi mà.

## 4. Yêu cầu failover trong chế độ Tự động

1. Wi-Fi là đường truyền ưu tiên; 4G là đường truyền dự phòng.
2. Chỉ coi một interface sẵn sàng khi đã có IP và kiểm tra được kết nối Internet bằng phép kiểm tra WAN độc lập với MQTT.
3. Nếu interface đang hoạt động mất WAN liên tiếp theo ngưỡng cấu hình, firmware phải dừng/kết thúc phiên MQTT trên interface đó, chọn interface dự phòng có WAN và kết nối lại MQTT.
4. Không chuyển đường truyền chỉ vì MQTT broker không phản hồi nếu WAN của interface hiện tại vẫn hoạt động. Khi đó firmware tiếp tục quy trình reconnect MQTT hiện có và báo lỗi broker.
5. Khi Wi-Fi phục hồi, chỉ failback từ 4G sang Wi-Fi sau khi Wi-Fi vượt qua số lần kiểm tra WAN thành công liên tiếp được cấu hình; tránh chuyển qua lại liên tục.
6. Mỗi lần chuyển interface phải cập nhật trạng thái active interface, trạng thái MQTT và bộ đếm failover để ứng dụng/telemetry có thể quan sát.
7. Nếu cả Wi-Fi và 4G đều không có WAN, thiết bị báo trạng thái mất mạng, tiếp tục kiểm tra và thử kết nối lại theo backoff có giới hạn; không làm treo vòng điều khiển/cảm biến.
8. Dữ liệu telemetry đang chờ gửi phải được giữ trong giới hạn bộ đệm hiện có; sau khi MQTT kết nối lại, gửi lại theo thứ tự phù hợp. Lệnh nhận trùng do reconnect phải được xử lý theo cơ chế chống thực thi lặp hiện có.
9. mục 2,3,4,5,6,7,8 hãy làm tương tự như luồng logic của wifi/ethernet.

## 5. Yêu cầu modem A7680C

- Khởi tạo modem bất đồng bộ hoặc trong task riêng; không chặn các tác vụ điều khiển quan trọng trong thời gian đăng ký mạng hoặc thiết lập PDP.
- Xác định và báo riêng các trạng thái: modem chưa sẵn sàng, SIM lỗi/không có SIM, chưa đăng ký mạng, PDP chưa kết nối, có IP, mất kết nối và đang khôi phục.
- Khi modem khởi động lại hoặc mất đăng ký mạng, firmware phải phát hiện, khôi phục theo trình tự an toàn và reconnect MQTT sau khi có IP.
- Timeout AT command, timeout đăng ký mạng và chu kỳ retry phải cấu hình được; retry có backoff và không tạo vòng lặp gửi AT liên tục.
- Firmware phải phát hiện modem bị treo khi không nhận phản hồi AT trong timeout cấu hình hoặc trạng thái modem không tiến triển quá thời gian cho phép. Mất sóng hay mất đăng ký mạng đơn thuần không được xem là modem bị treo.
- Khi phát hiện treo, firmware thử khôi phục bằng AT command nếu modem còn phản hồi; nếu không thành công, thực hiện reset cứng qua chân RESET/PWRKEY theo trình tự và thời gian quy định của A7680C. Sau reset, khởi tạo lại UART/modem, kiểm tra SIM, đăng ký mạng, thiết lập PDP và kết nối lại MQTT.
- Giới hạn số lần reset và áp dụng backoff giữa các lần để tránh reset liên tục. Trong thời gian modem được khôi phục, chế độ tự động được phép chuyển MQTT sang Wi-Fi nếu Wi-Fi có WAN; chế độ “Chỉ sử dụng 4G” tuyệt đối không dùng Wi-Fi.
- Ghi nhận và báo trạng thái/lý do reset để phục vụ chẩn đoán. Quá trình phát hiện và reset không được làm treo tác vụ điều khiển hoặc cảm biến.

## 6. Trạng thái hiển thị trên ứng dụng

Ứng dụng cần hiển thị:

- Chế độ đã chọn: giống với ethernet chỉ khác là checkbox Chỉ sử dụng 4G
- Đường truyền MQTT đang hoạt động: giống như cũ chỉ khác là đây là 4g
- Trạng thái kết nối MQTT: giống như cũ.
- Có log đầy đủ trong phần chẩn đoán về các warning hoặc error và Lưu lỗi vào nvm giống như cũ
Trạng thái interface và MQTT phải được báo riêng: có IP/WAN không đồng nghĩa MQTT đã kết nối.

## 7. Tiêu chí nghiệm thu

1. Chọn “Chỉ 4G” trên ứng dụng: thiết bị kết nối MQTT qua A7680C; tắt hoặc ngắt Wi-Fi vẫn không làm mất kết nối nếu 4G còn hoạt động.
2. Chọn “Chỉ 4G” và làm mất mạng di động: ứng dụng nhận trạng thái mất kết nối; thiết bị không chuyển sang Wi-Fi; khi 4G phục hồi, MQTT tự kết nối lại.
3. Mặc định bình thường cả 4g và wifi đều được sử dụng: khi Wi-Fi có WAN, MQTT dùng Wi-Fi; khi Wi-Fi mất WAN nhưng 4G có WAN, MQTT chuyển sang 4G; khi Wi-Fi phục hồi ổn định, thiết bị chuyển lại Wi-Fi.
4. Làm broker MQTT không khả dụng trong khi WAN vẫn hoạt động: thiết bị reconnect MQTT nhưng không đổi interface chỉ vì lỗi broker.
5. Khởi động lại thiết bị sau khi chọn từng chế độ: chế độ đã lưu được khôi phục và ứng dụng hiển thị đúng.
6. Trong lúc chuyển đường truyền và reconnect, tác vụ điều khiển/đọc cảm biến tiếp tục hoạt động; dữ liệu chờ gửi không vượt giới hạn bộ đệm.
7. Mất SIM, lỗi đăng ký mạng, lỗi PDP và modem reset được báo đúng trạng thái; firmware tiếp tục hoạt động và tự phục hồi khi điều kiện mạng trở lại.
8. Giả lập A7680C không phản hồi AT: firmware phát hiện modem treo theo timeout cấu hình, thực hiện quy trình khôi phục/reset có giới hạn, khởi tạo lại modem và kết nối MQTT khi 4G sẵn sàng.

## 8. Giả định cần xác nhận khi triển khai

- Mặc định ưu tiên Wi-Fi và dùng 4G làm dự phòng.
- Pinout UART0 TX=GPIO43, RX=GPIO44, RESET_N=GPIO1 và DTR=GPIO2 do người dùng xác nhận. APN phải được đặt theo SIM/nhà mạng; kiểm tra WAN hiện dùng các ping probe độc lập với MQTT và cần xác nhận hoạt động trên mạng di động thực tế.
- Ngưỡng phát hiện mất WAN, thời gian failback ổn định và chu kỳ retry giống như cũ
