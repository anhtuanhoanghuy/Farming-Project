import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/device_snapshot.dart';
import '../protocol/port_ids.dart';

/// What the UI shows for a load at one moment ([LoadController.captureLive]).
class LoadLive {
  const LoadLive({
    required this.name,
    required this.isOn,
    required this.stateKnown,
    required this.enabled,
    required this.delay,
    required this.delayReceivedAt,
  });

  final String name;
  final bool isOn;
  final bool stateKnown;
  final bool enabled;
  final LoadDelay delay;
  final DateTime delayReceivedAt;
}

/// State of one load, shared between the dashboard and the control page. It
/// mirrors what the ESP32 reports in its snapshots and events.
class LoadController extends ChangeNotifier {
  LoadController._(this.id) : _name = 'Tải $id';

  static final loads = [for (var id = 1; id <= 4; id++) LoadController._(id)];

  static LoadController get instance => loads.first;

  /// 1-based load number.
  final int id;
  String _name;
  bool _isOn = false;
  bool _enabled = true;
  bool _stateKnown = false;

  /// `DO1`..`DO4`.
  String get portId => PortIds.loadId(id);
  String get name => _name;
  bool get isOn => _isOn;
  bool get enabled => _enabled;

  /// False until the ESP32 has reported (snapshot or event) the real relay
  /// state; the screen then shows the state as unknown.
  bool get stateKnown => _stateKnown;

  String get title => _name;

  // ------------------------------------------------------------ delay timer

  LoadDelay _delay = const LoadDelay();
  DateTime _delayReceivedAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _ticker;

  /// Called once when the local countdown reaches zero, so the next phase can
  /// be read back from the ESP32.
  static void Function(LoadController load)? onDelayElapsed;

  /// True while the ESP32 runs a delay for this load.
  bool get delayActive => _delay.isRunning;

  /// State the load takes when the running phase ends (true = on).
  bool get delayTargetOn => _delay.targetOn ?? true;

  Duration get delayRemaining =>
      _delay.remainingAt(_delayReceivedAt, DateTime.now());

  String get delayCountdown {
    final s = delayRemaining.inSeconds;
    final h = s ~/ 3600;
    final m = ((s % 3600) ~/ 60).toString().padLeft(2, '0');
    final sec = (s % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$sec' : '$m:$sec';
  }

  /// Anchors the countdown on [delay] as it was in the snapshot received at
  /// [receivedAt]; the ESP32 publishes a new snapshot at every phase change,
  /// which re-anchors it.
  void applyDelay(LoadDelay delay, DateTime receivedAt) {
    _ticker?.cancel();
    _ticker = null;
    _delay = delay;
    _delayReceivedAt = receivedAt;
    if (delay.isRunning) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (delayRemaining == Duration.zero) {
          _ticker?.cancel();
          _ticker = null;
          notifyListeners();
          onDelayElapsed?.call(this);
        } else {
          notifyListeners();
        }
      });
    }
    notifyListeners();
  }

  void cancelDelay() {
    if (!_delay.isRunning && _ticker == null) return;
    applyDelay(const LoadDelay(), DateTime.now());
  }

  // ---------------------------------------------------------------- state

  /// Takes everything the snapshot says about this load. While a request of
  /// the user is waiting to be sent or acknowledged the snapshot is ignored,
  /// so quick taps do not make the screen jump between two states.
  void applySnapshot(
    LoadSnapshot snapshot,
    DateTime receivedAt, {
    bool acceptState = true,
  }) {
    if (busy) return;
    rename(snapshot.name);
    setEnabled(snapshot.enabled);
    if (acceptState) setOn(snapshot.state);
    applyDelay(snapshot.delay, receivedAt);
  }

  /// A relay state reported by an ESP32 event; ignored while the user's own
  /// request is still in flight.
  void setOnFromDevice(bool value) {
    if (!busy) setOn(value);
  }

  // ------------------------------------------------------ user requests

  /// Quiet time after the last tap before the command is sent: the screen
  /// follows every tap at once, but only the final request is sent.
  static const sendDelay = Duration(milliseconds: 400);

  Timer? _sendTimer;
  String? _burstKind;
  Future<void> Function()? _pendingFlush;
  LoadLive? _beforeRequest;
  int _inFlight = 0;
  int _ops = 0;

  /// True while a request waits to be sent or for its ACK.
  bool get busy => _sendTimer != null || _inFlight > 0 || _ops > 0;

  /// Marks a command the screen sends by itself (enable, rename...) so that
  /// snapshots do not overwrite what it shows until the ACK has come.
  void beginOp() => _ops++;
  void endOp() => _ops = _ops > 0 ? _ops - 1 : 0;

  /// BẬT / TẮT: shows [state] now and sends it after [sendDelay] without
  /// another tap. When [send] fails (refused, or no ACK within 5 s) the state
  /// shown before the first tap comes back and [onError] is called.
  void requestOnOff(
    bool state, {
    required Future<void> Function(bool state) send,
    required void Function(Object error) onError,
    VoidCallback? onShown,
    VoidCallback? onSettled,
  }) => _request(
    kind: 'onoff',
    show: () {
      cancelDelay();
      setOn(state);
      onShown?.call();
    },
    // Tapped back to where it started: nothing to tell the ESP32.
    unchanged: (before) =>
        before.stateKnown && before.isOn == state && !before.delay.isRunning,
    send: () => send(state),
    onError: onError,
    onSettled: onSettled,
  );

  /// Hẹn trễ: "Gửi yêu cầu" shows [shown] (the countdown) at once, "Dừng"
  /// ([stop]) clears it. Like [requestOnOff] only the last request is sent.
  void requestDelay({
    required LoadDelay shown,
    required bool stop,
    bool? turnOnNow,
    required Future<void> Function() send,
    required void Function(Object error) onError,
    VoidCallback? onSettled,
  }) => _request(
    kind: 'delay',
    show: () {
      if (turnOnNow != null) setOn(turnOnNow);
      if (stop) {
        cancelDelay();
      } else {
        applyDelay(shown, DateTime.now());
      }
    },
    unchanged: (before) => stop && !before.delay.isRunning,
    send: send,
    onError: onError,
    onSettled: onSettled,
  );

  void _request({
    required String kind,
    required VoidCallback show,
    required bool Function(LoadLive before) unchanged,
    required Future<void> Function() send,
    required void Function(Object error) onError,
    VoidCallback? onSettled,
  }) {
    // A different kind of request must not swallow the one still waiting.
    if (_sendTimer != null && _burstKind != kind) {
      _sendTimer!.cancel();
      _sendTimer = null;
      unawaited(_pendingFlush!());
    }
    _burstKind = kind;
    _beforeRequest ??= captureLive();
    show();
    _pendingFlush = () => _flush(unchanged, send, onError, onSettled);
    _sendTimer?.cancel();
    _sendTimer = Timer(sendDelay, () {
      _sendTimer = null;
      unawaited(_pendingFlush!());
    });
  }

  Future<void> _flush(
    bool Function(LoadLive before) unchanged,
    Future<void> Function() send,
    void Function(Object error) onError,
    VoidCallback? onSettled,
  ) async {
    final before = _beforeRequest!;
    _beforeRequest = null;
    if (unchanged(before)) {
      onSettled?.call();
      notifyListeners();
      return;
    }
    _inFlight++;
    try {
      await send();
      onSettled?.call();
    } catch (error) {
      // A newer request owns the screen now; it will settle on its own.
      if (_sendTimer == null && _beforeRequest == null) restoreLive(before);
      onError(error);
    } finally {
      _inFlight--;
    }
  }

  /// What the UI shows now, kept so an optimistic change can be undone when
  /// the ESP32 does not acknowledge it.
  LoadLive captureLive() => LoadLive(
    name: _name,
    isOn: _isOn,
    stateKnown: _stateKnown,
    enabled: _enabled,
    delay: _delay,
    delayReceivedAt: _delayReceivedAt,
  );

  void restoreLive(LoadLive live) {
    _name = live.name;
    _isOn = live.isOn;
    _stateKnown = live.stateKnown;
    _enabled = live.enabled;
    applyDelay(live.delay, live.delayReceivedAt);
  }

  void rename(String value) {
    final v = value.trim();
    if (v.isEmpty || v == _name) return;
    _name = v;
    notifyListeners();
  }

  void setOn(bool value) {
    if (value == _isOn && _stateKnown) return;
    _isOn = value;
    _stateKnown = true;
    notifyListeners();
  }

  /// The relay state can no longer be trusted (device offline, no MQTT).
  void markUnknown() {
    if (!_stateKnown) return;
    _stateKnown = false;
    notifyListeners();
  }

  void setEnabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}
