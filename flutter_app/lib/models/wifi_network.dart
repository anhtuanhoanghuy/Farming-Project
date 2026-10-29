/// Wi-Fi auth modes reported by the controller.
class WifiAuthMode {
  WifiAuthMode._();

  static const open = 0;
  static const wpa2Enterprise = 5;
}

class WifiNetwork {
  const WifiNetwork({
    required this.ssid,
    required this.rssi,
    required this.auth,
    this.channel = 0,
  });

  final String ssid;
  final int rssi;
  final int channel;
  final int auth;

  /// Enterprise networks need credentials beyond a password, so they are not selectable.
  bool get secured =>
      auth != WifiAuthMode.open && auth != WifiAuthMode.wpa2Enterprise;

  /// Keeps secured networks only, one entry per SSID (strongest signal), strongest first.
  static List<WifiNetwork> selectable(Iterable<WifiNetwork> all) {
    final best = <String, WifiNetwork>{};
    for (final n in all) {
      if (!n.secured || n.ssid.isEmpty) continue;
      final cur = best[n.ssid];
      if (cur == null || n.rssi > cur.rssi) best[n.ssid] = n;
    }
    return best.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
  }
}
