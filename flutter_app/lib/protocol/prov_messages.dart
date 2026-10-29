import 'dart:typed_data';

import 'proto_lite.dart';

/// ESP-IDF protocomm `session.proto` and `sec1.proto` messages.
class ProvMessages {
  ProvMessages._();

  static const _secScheme1 = 1;

  static Uint8List sec1Cmd0(Uint8List clientPubKey) {
    final sc0 = ProtoWriter()..writeBytes(1, clientPubKey);
    final sec1 = ProtoWriter()..writeMessage(20, sc0.toBytes());
    return _session(sec1);
  }

  static ({Uint8List devicePubKey, Uint8List deviceRandom}) parseSec1Resp0(
    Uint8List data,
  ) {
    final sr0 = _sec1Payload(data, 21);
    _expectOk(sr0.varint(1));
    final pub = sr0.bytes(2);
    final random = sr0.bytes(3);
    if (pub == null || random == null) {
      throw const FormatException('Missing device key material');
    }
    return (devicePubKey: pub, deviceRandom: random);
  }

  static Uint8List sec1Cmd1(Uint8List clientVerifyData) {
    final sc1 = ProtoWriter()..writeBytes(2, clientVerifyData);
    final sec1 = ProtoWriter()
      ..writeVarint(1, 2)
      ..writeMessage(22, sc1.toBytes());
    return _session(sec1);
  }

  static Uint8List parseSec1Resp1(Uint8List data) {
    final sr1 = _sec1Payload(data, 23);
    _expectOk(sr1.varint(1));
    return sr1.bytes(3) ?? Uint8List(0);
  }

  static Uint8List _session(ProtoWriter sec1) =>
      (ProtoWriter()
            ..writeVarint(2, _secScheme1)
            ..writeMessage(11, sec1.toBytes()))
          .toBytes();

  static ProtoFields _sec1Payload(Uint8List data, int field) {
    final sec1 = ProtoFields.parse(
      ProtoFields.parse(data).bytes(11) ?? const [],
    );
    final inner = sec1.bytes(field);
    if (inner == null) throw const FormatException('Unexpected session reply');
    return ProtoFields.parse(inner);
  }

  static void _expectOk(int status) {
    if (status != 0) throw FormatException('Device returned status $status');
  }
}
