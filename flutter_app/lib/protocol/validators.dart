class WifiPasswordRule {
  WifiPasswordRule._();

  static const minLength = 8;
  static const maxLength = 63;

  /// Returns a message when the input can never become valid; too short is not an error yet.
  static String? error(String value) {
    if (value.length > maxLength) return 'Mật khẩu tối đa $maxLength ký tự';
    final ascii = value.codeUnits.every((c) => c >= 0x20 && c <= 0x7e);
    if (!ascii) return 'Mật khẩu chỉ gồm chữ, số và ký hiệu ASCII';
    return null;
  }

  static bool isValid(String value) =>
      value.length >= minLength && error(value) == null;
}
