import 'dart:convert';
import 'dart:typed_data';

import '../models/wifi_network.dart';

class WifiScanException implements Exception {
  const WifiScanException(this.code);

  final String code;

  @override
  String toString() => code;
}

class WifiScanPage {
  const WifiScanPage({required this.total, required this.networks});

  final int total;
  final List<WifiNetwork> networks;
}

class WifiScanMessages {
  WifiScanMessages._();

  static const maxAccessPoints = 20;

  static Uint8List request(int start) {
    if (start < 0 || start > maxAccessPoints) {
      throw ArgumentError.value(start, 'start', 'Must be between 0 and 20');
    }
    return Uint8List.fromList(utf8.encode(jsonEncode({'start': start})));
  }

  static Future<List<WifiNetwork>> fetchAll(
    Future<Uint8List> Function(int start) sendRequest, {
    void Function(int start, WifiScanPage page)? onPage,
  }) async {
    final networks = <WifiNetwork>[];
    var total = -1;
    for (
      var requestCount = 0;
      requestCount < maxAccessPoints && (total < 0 || networks.length < total);
      requestCount++
    ) {
      final page = parseResponse(await sendRequest(networks.length));
      onPage?.call(networks.length, page);
      if (total >= 0 && page.total != total) {
        throw const FormatException('wifi-scan total changed between pages');
      }
      total = page.total;
      if (page.networks.isEmpty && networks.length < total) {
        throw const FormatException('wifi-scan returned an empty page early');
      }
      networks.addAll(page.networks);
    }
    if (networks.length < total) {
      throw const FormatException('wifi-scan exceeded the maximum page count');
    }
    return networks;
  }

  static WifiScanPage parseResponse(Uint8List payload) {
    final decoded = jsonDecode(utf8.decode(payload, allowMalformed: true));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('wifi-scan response must be a JSON object');
    }
    if (_containsWifiUnavailable(decoded)) {
      throw const WifiScanException('wifi_unavailable');
    }

    final total = decoded['total'];
    if (total is! int || total < 0 || total > maxAccessPoints) {
      throw FormatException(
        'Invalid wifi-scan total: expected 0..$maxAccessPoints, got $total',
      );
    }

    final candidateLists = decoded.entries
        .where(
          (entry) =>
              entry.key != 'total' &&
              entry.value is List &&
              (entry.value as List).every((item) => item is Map),
        )
        .toList();
    if (candidateLists.length != 1) {
      throw const FormatException(
        'wifi-scan response must contain exactly one AP list',
      );
    }

    final rawNetworks = candidateLists.single.value as List;
    final networks = <WifiNetwork>[];
    for (final raw in rawNetworks) {
      final item = raw as Map;
      final ssid = item['ssid'];
      final rssi = item['rssi'];
      final auth = item['auth'];
      if (ssid is! String || rssi is! int || auth is! int) {
        throw const FormatException(
          'Each wifi-scan AP must contain string ssid and integer rssi/auth',
        );
      }
      networks.add(WifiNetwork(ssid: ssid, rssi: rssi, auth: auth));
    }
    if (networks.length > total || networks.length > maxAccessPoints) {
      throw const FormatException('wifi-scan returned more APs than total');
    }
    return WifiScanPage(total: total, networks: networks);
  }

  static bool _containsWifiUnavailable(Object? value) {
    if (value == 'wifi_unavailable') return true;
    if (value is Map) return value.values.any(_containsWifiUnavailable);
    if (value is Iterable) return value.any(_containsWifiUnavailable);
    return false;
  }
}
