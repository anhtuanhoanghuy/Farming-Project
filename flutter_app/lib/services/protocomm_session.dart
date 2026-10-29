import 'dart:convert';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:pointycastle/export.dart';

import '../models/scanned_device.dart';
import '../protocol/prov_messages.dart';

class ProtocommException implements Exception {
  const ProtocommException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// BLE protocomm client with Security 1 (X25519 + AES-256-CTR), one GATT characteristic per endpoint.
class ProtocommSession {
  ProtocommSession._(this._device, this._endpoints);

  static const _endpointNameDescriptor = '2901';
  static final _wifiScanCharacteristicUuid = Guid('FF54');

  final BluetoothDevice _device;
  final Map<String, BluetoothCharacteristic> _endpoints;
  late final StreamCipher _cipher;
  Future<void> _queue = Future.value();
  bool _broken = false;

  static Future<ProtocommSession> open(
    String remoteId, {
    String pop = '',
  }) async {
    final device = BluetoothDevice.fromId(remoteId);
    await device.connect(
      license: License.nonprofit,
      timeout: const Duration(seconds: 15),
    );
    try {
      final session = ProtocommSession._(device, await _discover(device));
      await session._handshake(pop);
      return session;
    } catch (_) {
      await device.disconnect();
      rethrow;
    }
  }

  static Future<Map<String, BluetoothCharacteristic>> _discover(
    BluetoothDevice device,
  ) async {
    final services = await device.discoverServices();
    final service = services
        .where((s) => s.uuid == Guid(ScannedDevice.serviceUuid))
        .firstOrNull;
    if (service == null) {
      throw const ProtocommException(
        'Không tìm thấy dịch vụ cấu hình trên thiết bị',
      );
    }
    final endpoints = <String, BluetoothCharacteristic>{};
    BluetoothCharacteristic? wifiScanByUuid;
    for (final c in service.characteristics) {
      if (kDebugMode) {
        debugPrint('[BLE][discover] characteristic uuid=${c.uuid.str}');
      }
      for (final d in c.descriptors) {
        if (d.uuid != Guid(_endpointNameDescriptor)) continue;
        final name = utf8
            .decode(await d.read(), allowMalformed: true)
            .replaceAll('\u0000', '');
        if (kDebugMode) {
          debugPrint(
            '[BLE][discover] endpoint=$name characteristic=${c.uuid.str}',
          );
        }
        if (name.isNotEmpty) {
          endpoints[name] = c;
        }
      }
      if (c.uuid == _wifiScanCharacteristicUuid) {
        wifiScanByUuid = c;
      }
    }
    if (wifiScanByUuid != null) {
      endpoints['wifi-scan'] = wifiScanByUuid;
    }
    return endpoints;
  }

  Future<Uint8List> _raw(String endpoint, Uint8List data) async {
    final c = _endpoints[endpoint];
    if (c == null) {
      throw ProtocommException('Thiết bị không hỗ trợ endpoint $endpoint');
    }
    await c.write(data, allowLongWrite: true);
    return Uint8List.fromList(await c.read());
  }

  Future<void> _handshake(String pop) async {
    final x25519 = crypto.X25519();
    final keyPair = await x25519.newKeyPair();
    final clientPub = Uint8List.fromList(
      (await keyPair.extractPublicKey()).bytes,
    );

    final r0 = ProvMessages.parseSec1Resp0(
      await _raw('prov-session', ProvMessages.sec1Cmd0(clientPub)),
    );

    final secret = await x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: crypto.SimplePublicKey(
        r0.devicePubKey,
        type: crypto.KeyPairType.x25519,
      ),
    );
    final key = Uint8List.fromList(await secret.extractBytes());
    if (pop.isNotEmpty) {
      final hash = (await crypto.Sha256().hash(utf8.encode(pop))).bytes;
      for (var i = 0; i < key.length; i++) {
        key[i] ^= hash[i];
      }
    }

    // One keystream is shared by both directions, so every byte processed advances it.
    _cipher = SICStreamCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(key), r0.deviceRandom));

    final verify = _cipher.process(r0.devicePubKey);
    final reply = ProvMessages.parseSec1Resp1(
      await _raw('prov-session', ProvMessages.sec1Cmd1(verify)),
    );
    if (!listEquals(_cipher.process(reply), clientPub)) {
      throw const ProtocommException('Xác thực phiên bảo mật thất bại');
    }
  }

  /// Sends one encrypted request and returns the decrypted reply; calls are serialised.
  Future<Uint8List> send(String endpoint, Uint8List data) {
    final result = _queue.then((_) async {
      if (_broken) {
        throw const ProtocommException('Phiên kết nối đã bị gián đoạn');
      }
      try {
        final reply = await _raw(endpoint, _cipher.process(data));
        return _cipher.process(reply);
      } catch (_) {
        _broken = true;
        rethrow;
      }
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> close() async {
    try {
      await _device.disconnect();
    } catch (_) {
      // Already disconnected.
    }
  }
}
