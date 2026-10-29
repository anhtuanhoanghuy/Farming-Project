import 'dart:typed_data';

class ProtoWriter {
  final _out = BytesBuilder();

  void _varint(int value) {
    var n = value;
    while (n < 0 || n > 0x7f) {
      _out.addByte((n & 0x7f) | 0x80);
      n >>>= 7;
    }
    _out.addByte(n);
  }

  /// Proto3 omits default (zero) values.
  void writeVarint(int field, int value) {
    if (value == 0) return;
    _varint(field << 3);
    _varint(value);
  }

  void writeBytes(int field, List<int> data) {
    if (data.isEmpty) return;
    writeMessage(field, data);
  }

  /// Always written, so an empty sub-message still selects its `oneof` branch.
  void writeMessage(int field, List<int> data) {
    _varint((field << 3) | 2);
    _varint(data.length);
    _out.add(data);
  }

  Uint8List toBytes() => _out.toBytes();
}

class ProtoFields {
  ProtoFields._(this._fields);

  factory ProtoFields.parse(List<int> data) {
    final fields = <int, List<Object>>{};
    var pos = 0;

    int readVarint() {
      var result = 0;
      var shift = 0;
      while (true) {
        if (pos >= data.length || shift > 63) {
          throw const FormatException('Malformed protobuf varint');
        }
        final b = data[pos++];
        result |= (b & 0x7f) << shift;
        if (b & 0x80 == 0) return result;
        shift += 7;
      }
    }

    while (pos < data.length) {
      final tag = readVarint();
      final field = tag >> 3;
      switch (tag & 7) {
        case 0:
          fields.putIfAbsent(field, () => []).add(readVarint());
        case 2:
          final len = readVarint();
          if (len < 0 || pos + len > data.length) {
            throw const FormatException('Malformed protobuf length');
          }
          fields
              .putIfAbsent(field, () => [])
              .add(Uint8List.fromList(data.sublist(pos, pos + len)));
          pos += len;
        case 1:
          pos += 8;
        case 5:
          pos += 4;
        default:
          throw const FormatException('Unsupported protobuf wire type');
      }
    }
    return ProtoFields._(fields);
  }

  final Map<int, List<Object>> _fields;

  int varint(int field) {
    final v = _fields[field];
    return v != null && v.first is int ? v.first as int : 0;
  }

  Uint8List? bytes(int field) {
    final v = _fields[field];
    return v != null && v.first is Uint8List ? v.first as Uint8List : null;
  }

  List<Uint8List> repeatedBytes(int field) =>
      (_fields[field] ?? const []).whereType<Uint8List>().toList();
}
