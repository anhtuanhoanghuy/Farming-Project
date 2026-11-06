/// One line of the persistent error log the ESP32 keeps in flash (section
/// 2.21 / 6.9 of `mqtt_protocol.md`).
class DeviceLogEntry {
  const DeviceLogEntry({
    required this.seq,
    required this.boot,
    required this.level,
    required this.uptimeMs,
    required this.message,
    this.timestampMs,
  });

  /// Increases monotonically across reboots.
  final int seq;

  /// Boot counter of the run that wrote the line.
  final int boot;

  /// `E`, `W` or `I`.
  final String level;

  /// Milliseconds since that boot.
  final int uptimeMs;

  /// Wall-clock time in Unix milliseconds; null when the ESP32 clock was not
  /// valid yet.
  final int? timestampMs;

  /// "tag: text".
  final String message;

  bool get isError => level == 'E';
  bool get isWarning => level == 'W';

  static DeviceLogEntry? tryParse(Object? json) {
    if (json is! Map) return null;
    final seq = json['seq'];
    final boot = json['boot'];
    final level = json['level'];
    final uptime = json['uptime_ms'];
    final msg = json['msg'];
    if (seq is! num || level is! String || msg is! String) return null;
    final ts = json['ts'];
    return DeviceLogEntry(
      seq: seq.toInt(),
      boot: boot is num ? boot.toInt() : 0,
      level: level,
      uptimeMs: uptime is num ? uptime.toInt() : 0,
      timestampMs: ts is num ? ts.toInt() : null,
      message: msg,
    );
  }
}

/// A `LOGS` message of the `status` topic: one page of the error log.
class DeviceLogPage {
  const DeviceLogPage({
    required this.cmdId,
    required this.entries,
    required this.nextSeq,
    required this.more,
  });

  final String cmdId;

  /// Oldest first.
  final List<DeviceLogEntry> entries;

  /// `start_seq` of the next page.
  final int nextSeq;

  /// True when more entries follow [nextSeq].
  final bool more;

  /// Null when [json] is not a well-formed `LOGS` message.
  static DeviceLogPage? tryParse(Map<String, Object?> json) {
    if (json['type'] != 'LOGS') return null;
    final cmdId = json['cmd_id'];
    final nextSeq = json['next_seq'];
    final entries = json['entries'];
    if (cmdId is! String || nextSeq is! num || entries is! List) return null;
    return DeviceLogPage(
      cmdId: cmdId,
      entries: [for (final raw in entries) ?DeviceLogEntry.tryParse(raw)],
      nextSeq: nextSeq.toInt(),
      more: json['more'] == true,
    );
  }
}
