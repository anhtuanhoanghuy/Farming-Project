import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_app/models/wifi_network.dart';
import 'package:flutter_app/protocol/prov_messages.dart';
import 'package:flutter_app/protocol/proto_lite.dart';
import 'package:flutter_app/protocol/provisioning_messages.dart';
import 'package:flutter_app/protocol/validators.dart';
import 'package:flutter_app/protocol/wifi_scan_messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

void main() {
  test('prov-config uses the firmware fields including Ethernet-only mode', () {
    final body = ProvisioningMessages.configRequest(
      ssid: '',
      password: '',
      userId: '123e4567-e89b-12d3-a456-426614174000',
      onlyUseEthernet: true,
    );
    expect(jsonDecode(String.fromCharCodes(body)), {
      'ssid': '',
      'password': '',
      'user_id': '123e4567-e89b-12d3-a456-426614174000',
      'only_use_ethernet': true,
    });
  });

  test('prov-config accepts IN_PROGRESS and extracts the STA device ID', () {
    expect(
      ProvisioningMessages.parseConfigAccepted(
        Uint8List.fromList(
          '{"status":"IN_PROGRESS","device_id":"aabbccddeeff"}'.codeUnits,
        ),
      ),
      'aabbccddeeff',
    );
    expect(String.fromCharCodes(ProvisioningMessages.statusRequest()), '{}');
  });

  test('prov-status parses in-progress and completed Ethernet fallback', () {
    final pending = ProvisioningMessages.parseStatus(
      Uint8List.fromList(
        '{"state":"in_progress","device_id":"aabbccddeeff"}'.codeUnits,
      ),
    );
    expect(pending.state, ProvisioningState.inProgress);

    final done = ProvisioningMessages.parseStatus(
      Uint8List.fromList(
        '{"state":"done","status":"WARNING","saved":true,"attempts":2,'
                '"device_id":"aabbccddeeff","max_sensor_count":9,'
                '"max_load_count":4,"message":"Running on Ethernet"}'
            .codeUnits,
      ),
    );
    expect(done.state, ProvisioningState.done);
    expect(done.status, 'WARNING');
    expect(done.saved, isTrue);
    expect(done.attempts, 2);
    expect(done.maxSensorCount, 9);
    expect(done.maxLoadCount, 4);
    expect(done.message, 'Running on Ethernet');
  });

  test('provisioning rejects wrong fields and malformed device IDs', () {
    expect(
      () => ProvisioningMessages.parseConfigAccepted(
        Uint8List.fromList(
          '{"status":"IN_PROGRESS","device_id":"wrong"}'.codeUnits,
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => ProvisioningMessages.parseStatus(
        Uint8List.fromList(
          '{"state":"done","status":"SUCCESS","saved":"yes","attempts":0,'
                  '"device_id":"aabbccddeeff"}'
              .codeUnits,
        ),
      ),
      throwsFormatException,
    );
  });

  test('sec1 cmd0 carries scheme 1 and client key', () {
    final pub = Uint8List.fromList(List.generate(32, (i) => i));
    final root = ProtoFields.parse(ProvMessages.sec1Cmd0(pub));
    expect(root.varint(2), 1);
    final sec1 = ProtoFields.parse(root.bytes(11)!);
    expect(ProtoFields.parse(sec1.bytes(20)!).bytes(1), pub);
  });

  test('wifi-scan request is JSON with a start offset', () {
    expect(WifiScanMessages.request(0), '{"start":0}'.codeUnits);
    expect(WifiScanMessages.request(8), '{"start":8}'.codeUnits);
  });

  test('wifi-scan response parses total and AP data', () {
    final page = WifiScanMessages.parseResponse(
      Uint8List.fromList(
        '{"total":2,"aps":[{"ssid":"Pond","rssi":-45,"auth":3},'
                '{"ssid":"Guest","rssi":-71,"auth":0}]}'
            .codeUnits,
      ),
    );
    expect(page.total, 2);
    expect(page.networks.map((n) => (n.ssid, n.rssi, n.auth)).toList(), [
      ('Pond', -45, 3),
      ('Guest', -71, 0),
    ]);
  });

  test('wifi-scan fetches all cached pages using the next offset', () async {
    final requestedOffsets = <int>[];
    final result = await WifiScanMessages.fetchAll((start) async {
      requestedOffsets.add(start);
      final response = start == 0
          ? '{"total":3,"aps":[{"ssid":"A","rssi":-40,"auth":3},'
                '{"ssid":"B","rssi":-50,"auth":3}]}'
          : '{"total":3,"aps":[{"ssid":"C","rssi":-60,"auth":3}]}';
      return Uint8List.fromList(response.codeUnits);
    });

    expect(requestedOffsets, [0, 2]);
    expect(result.map((network) => network.ssid), ['A', 'B', 'C']);
  });

  test('wifi-scan surfaces radio unavailable error', () {
    expect(
      () => WifiScanMessages.parseResponse(
        Uint8List.fromList('{"error":"wifi_unavailable"}'.codeUnits),
      ),
      throwsA(
        isA<WifiScanException>().having(
          (e) => e.code,
          'code',
          'wifi_unavailable',
        ),
      ),
    );
  });

  test('wifi-scan rejects malformed page data', () {
    expect(
      () => WifiScanMessages.parseResponse(
        Uint8List.fromList(
          '{"total":1,"aps":[{"ssid":"Pond","rssi":"-45","auth":3}]}'.codeUnits,
        ),
      ),
      throwsFormatException,
    );
  });

  test('only secured networks are listed, deduplicated by SSID', () {
    WifiNetwork n(String s, int rssi, int auth) =>
        WifiNetwork(ssid: s, rssi: rssi, channel: 1, auth: auth);
    final out = WifiNetwork.selectable([
      n('A', -80, 3),
      n('A', -50, 3),
      n('Open', -40, 0),
      n('Corp', -45, 5),
      n('B', -60, 6),
    ]);
    expect(out.map((e) => (e.ssid, e.rssi)), [('A', -50), ('B', -60)]);
  });

  test('wifi password rule', () {
    expect(WifiPasswordRule.isValid('1234567'), isFalse);
    expect(WifiPasswordRule.isValid('12345678'), isTrue);
    expect(WifiPasswordRule.isValid('a' * 64), isFalse);
    expect(WifiPasswordRule.isValid('mật khẩu dài'), isFalse);
  });

  test('CTR keystream continues across calls like mbedtls', () {
    final key = Uint8List(32), iv = Uint8List(16)..[15] = 0xff;
    StreamCipher make() =>
        SICStreamCipher(AESEngine())
          ..init(true, ParametersWithIV(KeyParameter(key), iv));
    final data = Uint8List.fromList(List.generate(50, (i) => i));
    final whole = make().process(data);
    final c = make();
    final split = [
      ...c.process(data.sublist(0, 7)),
      ...c.process(data.sublist(7)),
    ];
    expect(split, whole);
  });
}
