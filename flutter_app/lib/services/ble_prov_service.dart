import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/app_config.dart';
import '../models/scanned_device.dart';
import '../models/wifi_network.dart';
import '../protocol/provisioning_messages.dart';
import '../protocol/network_interfaces.dart';
import '../protocol/wifi_scan_messages.dart';
import 'protocomm_session.dart';

/// BLE provisioning: Security 1 Wi-Fi scan (`wifi-scan`) and Wi-Fi config.
class BleProvisioningService {
  BleProvisioningService._(ProtocommSession session)
    : _send = session.send,
      _close = session.close;

  @visibleForTesting
  BleProvisioningService.test({
    required Future<Uint8List> Function(String, Uint8List) send,
    required Future<void> Function() close,
  }) : _send = send,
       _close = close;

  static const _wifiScanEndpoint = 'wifi-scan';
  static const _provisioningPollInterval = Duration(seconds: 1);
  static const _provisioningTimeout = Duration(seconds: 90);

  final Future<Uint8List> Function(String, Uint8List) _send;
  final Future<void> Function() _close;

  Future<NetworkInterfaces> readNetworkInterfaces() async {
    final status = ProvisioningMessages.parseStatus(
      await _send('prov-status', ProvisioningMessages.statusRequest()),
    );
    final interfaces = status.networkInterfaces;
    if (interfaces == null) {
      throw const ProtocommException(
        'Firmware chưa cung cấp khả năng mạng qua BLE. Hãy cập nhật firmware.',
      );
    }
    return interfaces;
  }

  static Future<BleProvisioningService> connect(ScannedDevice device) async =>
      BleProvisioningService._(
        await ProtocommSession.open(device.id, pop: AppConfig.pop),
      );

  Future<List<WifiNetwork>> scanWifi() => WifiScanMessages.fetchAll(
    (start) {
      if (kDebugMode) {
        debugPrint(
          '[BLE][wifi-scan] TX endpoint=$_wifiScanEndpoint uuid=0xFF54 start=$start',
        );
      }
      return _send(_wifiScanEndpoint, WifiScanMessages.request(start));
    },
    onPage: (start, page) {
      if (kDebugMode) {
        final aps = page.networks
            .map(
              (network) => {
                'ssid': network.ssid,
                'rssi': network.rssi,
                'auth': network.auth,
              },
            )
            .toList();
        debugPrint(
          '[BLE][wifi-scan] RX start=$start total=${page.total} '
          'page_count=${page.networks.length} aps=${jsonEncode(aps)}',
        );
      }
    },
  );

  Future<ProvisioningStatus> sendConfig({
    required String ssid,
    required String password,
    required String userId,
    required bool onlyUseEthernet,
    bool onlyUse4g = false,
  }) async {
    final acceptedDeviceId = ProvisioningMessages.parseConfigAccepted(
      await _send(
        'prov-config',
        ProvisioningMessages.configRequest(
          ssid: ssid,
          password: password,
          userId: userId,
          onlyUseEthernet: onlyUseEthernet,
          onlyUse4g: onlyUse4g,
        ),
      ),
    );

    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < _provisioningTimeout) {
      final status = ProvisioningMessages.parseStatus(
        await _send('prov-status', ProvisioningMessages.statusRequest()),
      );
      if (status.deviceId != acceptedDeviceId) {
        throw const ProtocommException(
          'device_id thay đổi trong phiên provisioning',
        );
      }
      if (status.state == ProvisioningState.done) {
        if (status.status == 'ERROR' || status.saved != true) {
          final detail =
              status.message ?? status.reason ?? status.code ?? status.status;
          throw ProtocommException(
            'Thiết lập mạng thất bại${detail == null ? '' : ': $detail'}',
          );
        }
        if (status.maxSensorCount == null || status.maxLoadCount == null) {
          throw const ProtocommException(
            'Thiết bị không gửi số lượng cảm biến/tải tối đa trong kết quả provisioning',
          );
        }
        return status;
      }
      await Future<void>.delayed(_provisioningPollInterval);
    }
    throw const ProtocommException(
      'Hết thời gian chờ kết quả provisioning (90 giây)',
    );
  }

  Future<void> close() => _close();
}
