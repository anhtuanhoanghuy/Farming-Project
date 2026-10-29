/// The `error_mask` bits the ESP32 reports in `errors.code_mask`, in the order
/// of its `SYS_ERR_*` flags.
class DeviceError {
  const DeviceError(
    this.bit,
    this.code,
    this.title,
    this.cause,
    this.advice, {
    this.severe = false,
  });

  final int bit;
  final String code;
  final String title;

  /// Why the firmware raises it.
  final String cause;

  /// What to check.
  final String advice;

  /// Shown as an error rather than a warning.
  final bool severe;

  int get mask => 1 << bit;

  static const all = [
    DeviceError(
      0,
      'SYS_ERR_MODBUS_TIMEOUT',
      'Cảnh báo truyền thông RS485',
      'một cảm biến RS485 không trả lời trong thời gian chờ.',
      'Kiểm tra dây A/B, nguồn cấp và địa chỉ Modbus của cảm biến.',
    ),
    DeviceError(
      1,
      'SYS_ERR_NET_LOST',
      'Cảnh báo mạng',
      'thiết bị mất kết nối Wi-Fi/Ethernet.',
      'Kiểm tra router, cáp mạng hoặc sóng Wi-Fi. Tải được giữ an toàn cho '
          'đến khi có mạng.',
    ),
    DeviceError(
      2,
      'SYS_ERR_MQTT_BROKER',
      'Không kết nối được broker MQTT',
      'mạng vẫn có nhưng broker từ chối hoặc không phản hồi.',
      'Kiểm tra địa chỉ, cổng và tài khoản của broker.',
      severe: true,
    ),
    DeviceError(
      3,
      'SYS_ERR_NVM_FAIL',
      'Lỗi lưu cấu hình (NVM)',
      'không ghi hoặc đọc được bộ nhớ cấu hình của thiết bị.',
      'Cấu hình mới có thể mất sau khi khởi động lại; thử cấu hình lại hoặc '
          'thay thiết bị nếu lỗi lặp lại.',
      severe: true,
    ),
    DeviceError(
      4,
      'SYS_ERR_SENSOR_OUT_RANGE',
      'Giá trị cảm biến ngoài dải',
      'một cảm biến báo giá trị vượt giới hạn hợp lệ.',
      'Kiểm tra đầu đo và cách lắp đặt.',
    ),
    DeviceError(
      5,
      'SYS_ERR_ETH_INIT',
      'Lỗi khởi tạo Ethernet',
      'module Ethernet không khởi tạo được hoặc kiểm tra phần cứng thất bại.',
      'Kiểm tra nguồn, module; xem log thiết bị.',
      severe: true,
    ),
    DeviceError(
      6,
      'SYS_ERR_INIT_FAILURE',
      'Lỗi khởi tạo firmware',
      'một thành phần quan trọng của hệ thống không khởi tạo thành công.',
      'Khởi động lại thiết bị; nếu lỗi còn, kiểm tra log và firmware.',
      severe: true,
    ),
    DeviceError(
      7,
      'SYS_ERR_RESOURCE_ALLOC',
      'Lỗi cấp phát tài nguyên',
      'firmware không cấp phát được tài nguyên cần thiết, như bộ nhớ hoặc queue.',
      'Khởi động lại thiết bị và kiểm tra log; nếu lặp lại, cần kiểm tra '
          'cấu hình và firmware.',
      severe: true,
    ),
    DeviceError(
      8,
      'SYS_ERR_LOAD_OUTPUT_DO1',
      'Lỗi ngõ ra DO1',
      'firmware không ghi được tín hiệu điều khiển tải DO1; trạng thái tải có '
          'thể không xác định.',
      'Kiểm tra mạch relay và dây tải DO1.',
    ),
    DeviceError(
      9,
      'SYS_ERR_LOAD_OUTPUT_DO2',
      'Lỗi ngõ ra DO2',
      'firmware không ghi được tín hiệu điều khiển tải DO2; trạng thái tải có '
          'thể không xác định.',
      'Kiểm tra mạch relay và dây tải DO2.',
    ),
    DeviceError(
      10,
      'SYS_ERR_LOAD_OUTPUT_DO3',
      'Lỗi ngõ ra DO3',
      'firmware không ghi được tín hiệu điều khiển tải DO3; trạng thái tải có '
          'thể không xác định.',
      'Kiểm tra mạch relay và dây tải DO3.',
    ),
    DeviceError(
      11,
      'SYS_ERR_LOAD_OUTPUT_DO4',
      'Lỗi ngõ ra DO4',
      'firmware không ghi được tín hiệu điều khiển tải DO4; trạng thái tải có '
          'thể không xác định.',
      'Kiểm tra mạch relay và dây tải DO4.',
    ),
  ];

  /// The errors set in [mask], in bit order. Unknown bits are returned as
  /// generic entries so that nothing the ESP32 reports is hidden.
  static List<DeviceError> fromMask(int mask) {
    final known = {for (final e in all) e.bit: e};
    final result = <DeviceError>[];
    for (var bit = 0; bit < 32; bit++) {
      if (mask & (1 << bit) == 0) continue;
      result.add(
        known[bit] ??
            DeviceError(
              bit,
              'SYS_ERR_BIT_$bit',
              'Lỗi chưa định nghĩa (bit $bit)',
              'firmware báo một lỗi mà app chưa biết.',
              'Cập nhật app hoặc xem log của thiết bị.',
            ),
      );
    }
    return result;
  }
}
