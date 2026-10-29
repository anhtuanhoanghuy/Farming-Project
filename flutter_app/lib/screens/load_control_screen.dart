import 'dart:async';

import 'package:flutter/material.dart';

import '../core/error_text.dart';
import '../models/device_selection.dart';
import '../navigation/app_routes.dart';
import '../protocol/device_snapshot.dart';
import '../protocol/device_telemetry.dart';
import '../protocol/load_automation.dart';
import '../protocol/mqtt_payloads.dart';
import '../protocol/port_ids.dart';
import '../services/crud_api.dart' show appMessengerKey;
import '../services/load_sync.dart';
import '../services/mqtt_session_manager.dart';
import '../state/device_state.dart';
import '../state/load_controller.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_buttons.dart';
import '../widgets/app_card.dart';
import '../widgets/app_more_menu.dart';
import '../widgets/app_anchored_dropdown.dart';
import '../widgets/app_text_field.dart';
import '../widgets/rename_dialog.dart';
import '../widgets/screen_scaffold.dart';
import '../widgets/time_wheel_field.dart';

String _formatNumber(double value) =>
    value == value.roundToDouble() ? '${value.toInt()}' : '$value';

/// Metrics a sensor publishes, as announced by the firmware snapshot.
List<String> _valueNamesFor(String portId) =>
    DeviceState.instance.snapshot?.input(portId)?.valueNames ?? const [];

/// What the user is editing for one sensor condition. It starts from the
/// snapshot and is replaced by it after each acknowledged command.
class _ConditionDraft {
  _ConditionDraft(LoadCondition condition)
    : id = condition.conditionId,
      threshold = TextEditingController() {
    load(condition);
  }

  final String id;
  final TextEditingController threshold;
  bool enabled = false;
  bool? action;
  String sensorId = '';
  String valueName = '';
  bool? greater;

  /// Set when the user tried to enable it with fields missing.
  bool showErrors = false;

  String? get sensorError =>
      showErrors && sensorId.isEmpty ? 'Hãy chọn cảm biến' : null;

  double? get thresholdValue {
    final value = double.tryParse(threshold.text.trim());
    return value != null && value.isFinite ? value : null;
  }

  String? get thresholdError =>
      showErrors && thresholdValue == null ? 'Nhập giá trị là số' : null;

  String? get valueError =>
      showErrors && valueName.isEmpty ? 'Chọn giá trị tham chiếu' : null;

  String? get actionError =>
      showErrors && action == null ? 'Hãy chọn hành động' : null;

  String? get conditionError =>
      showErrors && greater == null ? 'Hãy chọn điều kiện' : null;

  bool get isComplete =>
      sensorId.isNotEmpty &&
      valueName.isNotEmpty &&
      action != null &&
      greater != null &&
      thresholdValue != null;

  void load(LoadCondition condition) {
    enabled = condition.enabled;
    action = condition.sensorId.isEmpty ? null : condition.action;
    sensorId = condition.sensorId;
    valueName = condition.valueName;
    if (valueName.isEmpty && sensorId.isNotEmpty) {
      valueName =
          DeviceState.instance.reading(sensorId)?.values.firstOrNull?.name ??
          _valueNamesFor(sensorId).firstOrNull ??
          '';
    }
    greater = condition.sensorId.isEmpty ? null : condition.greater;
    showErrors = false;
    // A condition just added by the ESP32 has no sensor: leave the value blank.
    threshold.text = condition.sensorId.isEmpty && condition.threshold == 0
        ? ''
        : _formatNumber(condition.threshold);
  }
}

/// What the user is editing for one weekly schedule, in phone-local time.
class _ScheduleDraft {
  _ScheduleDraft(LoadSchedule schedule) : id = schedule.schedulerId {
    load(schedule);
  }

  final String id;
  TimeOfDay? onTime;
  TimeOfDay? offTime;
  bool enabled = false;

  /// Set when the user tried to enable it with fields missing.
  bool showErrors = false;

  /// 0 = Monday ... 6 = Sunday.
  final localDays = <int>{};

  String? get onError =>
      showErrors && onTime == null ? 'Hãy chọn giờ bật' : null;
  String? get offError =>
      showErrors && offTime == null ? 'Hãy chọn giờ tắt' : null;
  String? get daysError =>
      showErrors && localDays.isEmpty ? 'Hãy chọn ít nhất một ngày' : null;

  bool get isComplete =>
      onTime != null && offTime != null && localDays.isNotEmpty;

  void load(LoadSchedule schedule) {
    enabled = schedule.enabled;
    showErrors = false;
    localDays.clear();
    // A schedule just added by the ESP32 has no days and 00:00 times: the user
    // has to fill it in.
    if (schedule.daysMask == 0 &&
        schedule.onTimeUtc == '00:00' &&
        schedule.offTimeUtc == '00:00') {
      onTime = null;
      offTime = null;
      return;
    }
    final local = LoadAutomation.utcToLocal(
      utcDays: LoadAutomation.daysFromMask(schedule.daysMask),
      onTime: schedule.onTimeUtc,
      offTime: schedule.offTimeUtc,
    );
    localDays.addAll(local.localDays);
    onTime = TimeOfDay(hour: local.onHour, minute: local.onMinute);
    offTime = TimeOfDay(hour: local.offHour, minute: local.offMinute);
  }
}

class LoadControlScreen extends StatefulWidget {
  const LoadControlScreen({
    super.key,
    required this.device,
    required this.load,
    this.inShell = true,
  });

  final DeviceSelection device;
  final LoadController load;
  final bool inShell;

  @override
  State<LoadControlScreen> createState() => _LoadControlScreenState();
}

class _LoadControlScreenState extends State<LoadControlScreen> {
  static const _maxSchedules = 3;
  static const _maxConditions = 2;

  final _delay = TextEditingController();
  final _duration = TextEditingController();
  final _weekdays = const ['T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'CN'];

  final _conditions = <String, _ConditionDraft>{};
  final _schedules = <String, _ScheduleDraft>{};

  /// Drafts removed from the screen; their controllers are disposed with it
  /// because the widgets using them are still mounted for one more frame.
  final _retired = <ChangeNotifier>[];

  /// Delay mode: true = wait then turn on, false = wait then turn off.
  bool _turnOnFirst = true;
  bool _delayFormLoaded = false;

  /// Commands sent from this screen that wait for their ACK.
  int _pending = 0;

  DeviceSnapshot? _seenSnapshot;

  /// After an acknowledged command the next snapshot replaces every draft:
  /// the ESP32 is the source of truth.
  bool _resync = false;

  LoadController get _load => widget.load;
  String get _mac => widget.device.deviceId;

  LoadSnapshot? get _snapshotLoad =>
      DeviceState.instance.snapshot?.load(_load.portId);

  @override
  void initState() {
    super.initState();
    DeviceState.instance.addListener(_onDeviceStateChanged);
    _delay.addListener(_refresh);
    _duration.addListener(_refresh);
    _syncFromSnapshot(force: true);
  }

  @override
  void dispose() {
    DeviceState.instance.removeListener(_onDeviceStateChanged);
    for (final draft in _conditions.values) {
      _retired.add(draft.threshold);
    }
    for (final controller in _retired) {
      controller.dispose();
    }
    _delay.dispose();
    _duration.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------------ data

  void _onDeviceStateChanged() {
    if (!mounted) return;
    if (identical(DeviceState.instance.snapshot, _seenSnapshot)) {
      setState(() {
        for (final draft in _conditions.values) {
          if (draft.valueName.isEmpty && draft.sensorId.isNotEmpty) {
            draft.valueName =
                DeviceState.instance
                    .reading(draft.sensorId)
                    ?.values
                    .firstOrNull
                    ?.name ??
                _valueNamesFor(draft.sensorId).firstOrNull ??
                '';
          }
        }
      });
      return;
    }
    // A command is still waiting for its ACK: the next snapshot (published
    // right after the ACK) brings the settled state.
    if (_pending > 0 || _load.busy) return;
    final force = _resync;
    _resync = false;
    setState(() => _syncFromSnapshot(force: force));
  }

  /// Takes the snapshot's conditions and schedules. Unsaved edits of an item
  /// survive a periodic snapshot; [force] replaces them.
  void _syncFromSnapshot({required bool force}) {
    final snapshot = DeviceState.instance.snapshot;
    _seenSnapshot = snapshot;
    final load = _snapshotLoad;
    final conditions = load?.conditions ?? const <LoadCondition>[];
    final schedules = load?.schedules ?? const <LoadSchedule>[];

    for (final id in [..._conditions.keys]) {
      if (conditions.every((c) => c.conditionId != id)) {
        _retired.add(_conditions.remove(id)!.threshold);
      }
    }
    for (final condition in conditions) {
      final draft = _conditions[condition.conditionId];
      if (draft == null) {
        _conditions[condition.conditionId] = _ConditionDraft(condition);
      } else if (force) {
        draft.load(condition);
      }
    }

    for (final id in [..._schedules.keys]) {
      if (schedules.every((s) => s.schedulerId != id)) {
        _schedules.remove(id);
      }
    }
    for (final schedule in schedules) {
      final draft = _schedules[schedule.schedulerId];
      if (draft == null) {
        _schedules[schedule.schedulerId] = _ScheduleDraft(schedule);
      } else if (force) {
        draft.load(schedule);
      }
    }

    if (load != null && !_delayFormLoaded) {
      _delayFormLoaded = true;
      if (load.delay.delayMin > 0 || load.delay.duration > 0) {
        _delay.text = '${load.delay.delayMin}';
        _duration.text = '${load.delay.duration}';
        _turnOnFirst = !load.delay.offThenOn;
      }
    }
  }

  List<_ConditionDraft> get _sortedConditions =>
      _conditions.values.toList()..sort((a, b) => a.id.compareTo(b.id));

  List<_ScheduleDraft> get _sortedSchedules =>
      _schedules.values.toList()..sort((a, b) => a.id.compareTo(b.id));

  /// Ports of the configured sensors, for the condition sensor dropdown.
  List<SensorInput> get _sensors =>
      (DeviceState.instance.snapshot?.inputs ?? const [])
          .where((input) => !PortIds.isReservedLoadSensorName(input.name))
          .toList();

  // ------------------------------------------------------------- plumbing

  void _notify(String message) {
    final messenger = mounted
        ? ScaffoldMessenger.of(context)
        : appMessengerKey.currentState;
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Runs a check before anything is shown; false (with a message) when it
  /// throws.
  bool _check(String failure, void Function() validate) {
    try {
      validate();
      return true;
    } catch (error) {
      _notify(userErrorText(failure, error));
      return false;
    }
  }

  /// Shows the change at once and sends the command. When the ESP32 refuses it
  /// or stays silent for 5 s, [revert] puts back what was shown before and the
  /// real state is requested. [onAcked] runs after a successful ACK.
  Future<void> _optimistic({
    required String failure,
    required VoidCallback apply,
    required VoidCallback revert,
    required Map<String, Object?> payload,
    VoidCallback? onAcked,
    bool loadLevel = false,
  }) async {
    // Until the ACK nothing from the ESP32 may overwrite what is shown.
    _pending++;
    if (loadLevel) _load.beginOp();
    setState(apply);
    try {
      await _send(payload);
    } catch (error) {
      if (mounted) {
        setState(revert);
      } else {
        revert();
      }
      _notify(userErrorText(failure, error));
      unawaited(LoadSync.instance.requestStatus());
      return;
    } finally {
      _pending--;
      if (loadLevel) _load.endOp();
    }
    _resync = true;
    onAcked?.call();
  }

  Future<void> _send(Map<String, Object?> payload) =>
      MqttSessionManager.instance.publishCommandAndWaitForAck(_mac, payload);

  void _requireEnabled() {
    if (!_load.enabled) {
      throw StateError('Tải đang bị khóa; hãy bật Cho phép điều khiển tải.');
    }
  }

  // --------------------------------------------------------- load commands

  /// BẬT / TẮT now: it also stops the delay and switches every condition and
  /// schedule of the load off. The screen follows every tap at once; the
  /// command goes out after a short quiet time with the last state only.
  void _setStateOnDevice(bool state) {
    _load.requestOnOff(
      state,
      send: (state) => _send(
        MqttPayloads.setLoadState(
          cmdId: MqttPayloads.newCommandId(),
          loadId: _load.portId,
          on: state,
        ),
      ),
      onShown: () {
        if (!mounted) return;
        setState(() {
          for (final draft in _conditions.values) {
            draft.enabled = false;
          }
          for (final draft in _schedules.values) {
            draft.enabled = false;
          }
        });
      },
      // The ESP32's snapshot decides the drafts again (also after a failure).
      onSettled: () => _resync = true,
      onError: (error) {
        _resync = true;
        _notify(userErrorText('Giao tiếp với thiết bị thất bại', error));
        unawaited(LoadSync.instance.requestStatus());
      },
    );
  }

  /// "Gửi yêu cầu": one-shot delay (SET_LOAD_DELAY). The countdown starts at
  /// once; the snapshot the ESP32 publishes next re-anchors it.
  Future<void> _sendDelay() {
    const failure = 'Không gửi được hẹn giờ trễ';
    final delayMin = int.tryParse(_delay.text.trim());
    final duration = int.tryParse(_duration.text.trim());
    final valid = _check(failure, () {
      _requireEnabled();
      if (delayMin == null ||
          duration == null ||
          delayMin < 1 ||
          delayMin > 1440 ||
          duration < 0 ||
          duration > 1440) {
        throw const FormatException(
          'Thời gian bật/tắt phải từ 1 đến 1440 phút; thời lượng phải từ 0 đến 1440 phút.',
        );
      }
    });
    if (!valid) return Future.value();
    final minutes = delayMin!;
    final length = duration!;
    _requestDelay(minutes, length);
    return Future.value();
  }

  /// Shows the countdown at once and sends SET_LOAD_DELAY after a short quiet
  /// time (the last tap wins); it comes back when the ESP32 does not ACK.
  void _requestDelay(int minutes, int length) {
    final firstPhase = minutes > 0;
    _load.requestDelay(
      stop: false,
      // No first phase to wait for: the load takes its first state now.
      turnOnNow: minutes == 0 ? _turnOnFirst : null,
      shown: (minutes == 0 && length == 0)
          ? const LoadDelay()
          : LoadDelay(
              active: true,
              offThenOn: !_turnOnFirst,
              delayMin: minutes,
              duration: length,
              phase: firstPhase ? DelayPhase.waitFirst : DelayPhase.waitSecond,
              remainingSeconds: (firstPhase ? minutes : length) * 60,
            ),
      send: () => _send(
        MqttPayloads.setLoadDelay(
          cmdId: MqttPayloads.newCommandId(),
          loadId: _load.portId,
          offThenOn: !_turnOnFirst,
          delayMin: minutes,
          duration: length,
        ),
      ),
      onSettled: () => _resync = true,
      onError: (error) {
        _notify(userErrorText('Không gửi được hẹn giờ trễ', error));
        unawaited(LoadSync.instance.requestStatus());
      },
    );
  }

  /// "Dừng": the countdown disappears at once; STOP_LOAD_DELAY follows after
  /// a short quiet time.
  void _stopDelay() {
    _load.requestDelay(
      stop: true,
      shown: const LoadDelay(),
      send: () => _send(
        MqttPayloads.stopLoadDelay(
          cmdId: MqttPayloads.newCommandId(),
          loadId: _load.portId,
        ),
      ),
      onSettled: () => _resync = true,
      onError: (error) {
        _notify(userErrorText('Không dừng được hẹn giờ', error));
        unawaited(LoadSync.instance.requestStatus());
      },
    );
  }

  /// "Cho phép tải": the ESP32 clears the delay, conditions and schedules of a
  /// disabled load and keeps it off.
  Future<void> _toggleEnabled(bool value) {
    final before = _load.captureLive();
    return _optimistic(
      loadLevel: true,
      failure: 'Không đổi được quyền điều khiển tải',
      apply: () => _load
        ..cancelDelay()
        ..setOn(false)
        ..setEnabled(value),
      revert: () => _load.restoreLive(before),
      payload: MqttPayloads.toggleLoadCapability(
        cmdId: MqttPayloads.newCommandId(),
        loadId: _load.portId,
        enabled: value,
      ),
      onAcked: () {
        if (!mounted) return;
        setState(() {
          for (final draft in _conditions.values) {
            _retired.add(draft.threshold);
          }
          _conditions.clear();
          _schedules.clear();
        });
      },
    );
  }

  Future<void> _rename() async {
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(
        title: 'Đổi tên tải',
        hint: 'Tên tải',
        initial: _load.name,
      ),
    );
    final name = newName?.trim();
    if (name == null || name.isEmpty || !mounted) return;
    final before = _load.captureLive();
    await _optimistic(
      loadLevel: true,
      failure: 'Không đổi được tên tải',
      apply: () => _load.rename(name),
      revert: () => _load.restoreLive(before),
      payload: MqttPayloads.setLoadName(
        cmdId: MqttPayloads.newCommandId(),
        loadId: _load.portId,
        name: name,
      ),
    );
  }

  // ------------------------------------------------------------ conditions

  String? get _freeConditionId => PortIds.conditionIds
      .where((id) => !_conditions.containsKey(id))
      .firstOrNull;

  Future<bool> _confirmAutomationPriority() async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: AppColors.surface,
            surfaceTintColor: Colors.transparent,
            title: const Text(
              'Lưu ý khi kết hợp kịch bản',
              style: AppTextStyles.sectionTitle,
            ),
            content: const SingleChildScrollView(
              child: Text(
                'Có thể bật đồng thời Hẹn giờ trễ, Điều kiện cảm biến và Lịch hẹn. '
                'Khi cùng tác động lên một tải, thứ tự ưu tiên là:\n\n'
                'Dừng khẩn cấp → Tải bị vô hiệu hóa → Điều khiển thủ công → '
                'Hẹn giờ trễ → Điều kiện cảm biến → Lịch hẹn\n\n'
                'Trong thời gian Hẹn giờ trễ đang chạy, điều kiện cảm biến và '
                'lịch hẹn không điều khiển tải. Khi hẹn giờ kết thúc, các kịch '
                'bản tự động có thể tiếp tục tác động theo thứ tự ưu tiên ở trên.\n\n'
                'Điều kiện cảm biến được ưu tiên hơn lịch. Nếu điều kiện đang '
                'thỏa mãn đúng lúc đến giờ bật/tắt, sự kiện lịch có thể bị bỏ '
                'qua và không tự chạy bù sau đó.\n\n'
                'Thao tác điều khiển thủ công sẽ tắt các điều kiện và lịch đang '
                'bật cho tải đó.',
                style: AppTextStyles.bodySecondary,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(
                  'Hủy',
                  style: AppTextStyles.link.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(
                  'Đã hiểu, tiếp tục',
                  style: AppTextStyles.link.copyWith(color: AppColors.primary),
                ),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _addCondition() async {
    const failure = 'Không thêm được điều kiện';
    String? id;
    final valid = _check(failure, () {
      _requireEnabled();
      id = _freeConditionId;
      if (id == null) throw StateError('Đã đủ $_maxConditions điều kiện.');
    });
    if (!valid) return;
    if (!await _confirmAutomationPriority() || !mounted) return;
    final conditionId = id!;
    final draft = _ConditionDraft(
      LoadCondition(
        conditionId: conditionId,
        enabled: false,
        action: false,
        sensorId: '',
        valueName: '',
        greater: false,
        threshold: 0,
      ),
    );
    await _optimistic(
      failure: failure,
      apply: () => _conditions[conditionId] = draft,
      revert: () {
        _conditions.remove(conditionId);
        _retired.add(draft.threshold);
      },
      payload: MqttPayloads.addLoadCondition(
        cmdId: MqttPayloads.newCommandId(),
        loadId: _load.portId,
        conditionId: conditionId,
      ),
    );
  }

  /// The switch is the "apply" of a condition. Turning it on sends the whole
  /// condition (SET_LOAD_CONDITION) once every field is filled in; otherwise
  /// the missing fields turn red and the switch stays off. Turning it off
  /// only disables it (TOGGLE_LOAD_CONDITION). The switch moves at once.
  Future<void> _toggleCondition(_ConditionDraft draft, bool value) {
    const failure = 'Không đổi được trạng thái điều kiện';
    if (!_check(failure, _requireEnabled)) return Future.value();
    if (value && !draft.isComplete) {
      setState(() => draft.showErrors = true);
      return Future.value();
    }
    return _optimistic(
      failure: failure,
      apply: () {
        draft.enabled = value;
        draft.showErrors = false;
      },
      revert: () => draft.enabled = !value,
      payload: value
          ? MqttPayloads.setLoadCondition(
              cmdId: MqttPayloads.newCommandId(),
              loadId: _load.portId,
              conditionId: draft.id,
              conditionEnabled: true,
              action: draft.action!,
              sensorId: draft.sensorId,
              valueName: draft.valueName,
              greater: draft.greater!,
              threshold: draft.thresholdValue!,
            )
          : MqttPayloads.toggleLoadCondition(
              cmdId: MqttPayloads.newCommandId(),
              loadId: _load.portId,
              conditionId: draft.id,
              enabled: false,
            ),
    );
  }

  Future<void> _deleteCondition(_ConditionDraft draft) => _optimistic(
    failure: 'Không xóa được điều kiện',
    apply: () => _conditions.remove(draft.id),
    revert: () => _conditions[draft.id] = draft,
    payload: MqttPayloads.deleteLoadCondition(
      cmdId: MqttPayloads.newCommandId(),
      loadId: _load.portId,
      conditionId: draft.id,
    ),
    onAcked: () => _retired.add(draft.threshold),
  );

  // -------------------------------------------------------------- schedule

  String? get _freeSchedulerId => PortIds.schedulerIds
      .where((id) => !_schedules.containsKey(id))
      .firstOrNull;

  Future<void> _addSchedule() async {
    const failure = 'Không thêm được lịch hẹn';
    String? id;
    final valid = _check(failure, () {
      _requireEnabled();
      id = _freeSchedulerId;
      if (id == null) throw StateError('Đã đủ $_maxSchedules lịch hẹn.');
    });
    if (!valid) return;
    if (!await _confirmAutomationPriority() || !mounted) return;
    final schedulerId = id!;
    final draft = _ScheduleDraft(
      LoadSchedule(
        schedulerId: schedulerId,
        enabled: false,
        daysMask: 0,
        onTimeUtc: '00:00',
        offTimeUtc: '00:00',
      ),
    );
    await _optimistic(
      failure: failure,
      apply: () => _schedules[schedulerId] = draft,
      revert: () => _schedules.remove(schedulerId),
      payload: MqttPayloads.addLoadScheduler(
        cmdId: MqttPayloads.newCommandId(),
        loadId: _load.portId,
        schedulerId: schedulerId,
      ),
    );
  }

  /// The switch is the "apply" of a schedule. Turning it on sends the whole
  /// schedule (SET_LOAD_SCHEDULE, local times converted to UTC) once times and
  /// days are chosen; otherwise the missing fields turn red and the switch
  /// stays off. Turning it off only disables it (TOGGLE_LOAD_SCHEDULER). The
  /// switch moves at once.
  Future<void> _toggleSchedule(_ScheduleDraft draft, bool value) {
    const failure = 'Không đổi được trạng thái lịch hẹn';
    if (!_check(failure, _requireEnabled)) return Future.value();
    if (value && !draft.isComplete) {
      setState(() => draft.showErrors = true);
      return Future.value();
    }
    Map<String, Object?> payload;
    if (value) {
      final utc = LoadAutomation.localToUtc(
        localDays: draft.localDays,
        onHour: draft.onTime!.hour,
        onMinute: draft.onTime!.minute,
        offHour: draft.offTime!.hour,
        offMinute: draft.offTime!.minute,
      );
      payload = MqttPayloads.setLoadSchedule(
        cmdId: MqttPayloads.newCommandId(),
        loadId: _load.portId,
        schedulerId: draft.id,
        schedulerEnabled: true,
        daysMask: utc.daysMask,
        onTimeUtc: utc.onTime,
        offTimeUtc: utc.offTime,
      );
    } else {
      payload = MqttPayloads.toggleLoadScheduler(
        cmdId: MqttPayloads.newCommandId(),
        loadId: _load.portId,
        schedulerId: draft.id,
        enabled: false,
      );
    }
    return _optimistic(
      failure: failure,
      apply: () {
        draft.enabled = value;
        draft.showErrors = false;
      },
      revert: () => draft.enabled = !value,
      payload: payload,
    );
  }

  Future<void> _deleteSchedule(_ScheduleDraft draft) => _optimistic(
    failure: 'Không xóa được lịch hẹn',
    apply: () => _schedules.remove(draft.id),
    revert: () => _schedules[draft.id] = draft,
    payload: MqttPayloads.deleteLoadScheduler(
      cmdId: MqttPayloads.newCommandId(),
      loadId: _load.portId,
      schedulerId: draft.id,
    ),
  );

  // -------------------------------------------------------------------- UI

  /// Small red "Xóa" pill, as in the design.
  Widget _deletePill(VoidCallback? onTap) => InkWell(
    borderRadius: BorderRadius.circular(8),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.errorBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'Xóa',
        style: AppTextStyles.chip.copyWith(color: AppColors.errorText),
      ),
    ),
  );

  /// Card header: title on the left; enable/disable switch then "Xóa" on the
  /// right.
  Widget _cardHeader(
    String title, {
    required bool value,
    required ValueChanged<bool>? onChanged,
    required VoidCallback? onDelete,
  }) => Row(
    children: [
      Expanded(child: Text(title, style: AppTextStyles.cardTitle)),
      Switch(value: value, onChanged: onChanged),
      const SizedBox(width: 6),
      _deletePill(onDelete),
    ],
  );

  Widget _fieldLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: AppTextStyles.label),
  );

  static String _numberOf(String id) => id.replaceAll(RegExp(r'\D'), '');

  Widget _scheduleCard(_ScheduleDraft draft) {
    final locked = draft.enabled;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardHeader(
            'Lịch hẹn ${_numberOf(draft.id)}',
            value: draft.enabled,
            onChanged: (v) => _toggleSchedule(draft, v),
            onDelete: () => _deleteSchedule(draft),
          ),
          const SizedBox(height: 8),
          TimeWheelField(
            label: 'Giờ bật',
            value: draft.onTime,
            errorText: draft.onError,
            enabled: !locked,
            onChanged: (time) => setState(() => draft.onTime = time),
          ),
          const SizedBox(height: 12),
          TimeWheelField(
            label: 'Giờ tắt',
            value: draft.offTime,
            errorText: draft.offError,
            enabled: !locked,
            onChanged: (time) => setState(() => draft.offTime = time),
          ),
          const SizedBox(height: 12),
          _fieldLabel('Ngày áp dụng'),
          Wrap(
            spacing: 2,
            runSpacing: 2,
            children: [
              for (var day = 0; day < _weekdays.length; day++)
                InkWell(
                  onTap: locked
                      ? null
                      : () => setState(
                          () => draft.localDays.contains(day)
                              ? draft.localDays.remove(day)
                              : draft.localDays.add(day),
                        ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: draft.localDays.contains(day),
                        visualDensity: VisualDensity.compact,
                        isError: draft.daysError != null,
                        onChanged: locked
                            ? null
                            : (selected) => setState(
                                () => selected == true
                                    ? draft.localDays.add(day)
                                    : draft.localDays.remove(day),
                              ),
                      ),
                      Text(_weekdays[day], style: AppTextStyles.bodySecondary),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
            ],
          ),
          if (draft.daysError != null)
            Text(
              draft.daysError!,
              style: AppTextStyles.caption.copyWith(color: AppColors.danger),
            ),
          const Text(
            'Điền đủ thông tin rồi gạt công tắc để áp dụng; tắt công tắc để '
            'chỉnh sửa.',
            style: AppTextStyles.caption,
          ),
        ],
      ),
    );
  }

  Widget _addScheduleButton() {
    final count = _schedules.length;
    final full = count >= _maxSchedules;
    return Column(
      children: [
        if (full)
          GhostButton(
            label: 'Thêm lịch hẹn ($count/$_maxSchedules)',
            onPressed: null,
          )
        else
          OutlineAppButton(
            label: 'Thêm lịch hẹn ($count/$_maxSchedules)',
            icon: Icons.add,
            onPressed: _load.enabled ? _addSchedule : null,
          ),
      ],
    );
  }

  Widget _conditionCard(_ConditionDraft draft) {
    final sensors = _sensors;
    final knownSensor = sensors.any((s) => s.portId == draft.sensorId);
    final locked = draft.enabled;
    final telemetryValues =
        DeviceState.instance.reading(draft.sensorId)?.values ??
        const <TelemetryValue>[];
    final valueNames = telemetryValues.isNotEmpty
        ? telemetryValues.map((value) => value.name).toList(growable: false)
        : _valueNamesFor(draft.sensorId);
    final knownValue = valueNames.contains(draft.valueName);
    final valueOptions = <AppDropdownOption<String>>[
      for (final name in valueNames)
        AppDropdownOption(value: name, label: name),
      if (draft.valueName.isNotEmpty && !knownValue)
        AppDropdownOption(value: draft.valueName, label: draft.valueName),
    ];
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardHeader(
            'Điều kiện ${_numberOf(draft.id)}',
            value: draft.enabled,
            onChanged: (v) => _toggleCondition(draft, v),
            onDelete: () => _deleteCondition(draft),
          ),
          const SizedBox(height: 8),
          _fieldLabel('Hành động'),
          AppAnchoredDropdownField<bool>(
            key: ValueKey(
              'action-${draft.id}-${draft.action}-${draft.actionError != null}',
            ),
            value: draft.action,
            hint: 'Chọn hành động',
            errorText: draft.actionError,
            options: const [
              AppDropdownOption(value: true, label: 'Bật khi'),
              AppDropdownOption(value: false, label: 'Tắt khi'),
            ],
            enabled: !locked,
            onChanged: (value) => setState(() => draft.action = value),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _fieldLabel('Cảm biến'),
                    AppAnchoredDropdownField<String>(
                      key: ValueKey(
                        'sensor-${draft.id}-${draft.sensorId}-${sensors.length}'
                        '-${draft.sensorError != null}',
                      ),
                      value: draft.sensorId.isEmpty ? null : draft.sensorId,
                      hint: 'Chọn cảm biến',
                      errorText: draft.sensorError,
                      options: [
                        for (final sensor in sensors)
                          AppDropdownOption(
                            value: sensor.portId,
                            label: '${sensor.name}',
                          ),
                        if (draft.sensorId.isNotEmpty && !knownSensor)
                          AppDropdownOption(
                            value: draft.sensorId,
                            label: '${draft.sensorId} (không có)',
                          ),
                      ],
                      enabled: !locked,
                      onChanged: (value) {
                        final firstValue =
                            DeviceState.instance
                                .reading(value)
                                ?.values
                                .firstOrNull
                                ?.name ??
                            _valueNamesFor(value).firstOrNull ??
                            '';
                        setState(() {
                          draft.sensorId = value;
                          draft.valueName = firstValue;
                        });
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _fieldLabel('Tham chiếu'),
                    AppAnchoredDropdownField<String>(
                      key: ValueKey(
                        'value-${draft.id}-${draft.sensorId}-${draft.valueName}'
                        '-${valueNames.length}-${draft.valueError != null}',
                      ),
                      value: draft.valueName.isEmpty ? null : draft.valueName,
                      hint: valueNames.isEmpty
                          ? 'Chọn cảm biến trước'
                          : 'Chọn tham chiếu',
                      errorText: draft.valueError,
                      options: valueOptions,
                      enabled: !locked && valueOptions.isNotEmpty,
                      onChanged: (value) =>
                          setState(() => draft.valueName = value),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _fieldLabel('Điều kiện'),
                    AppAnchoredDropdownField<bool>(
                      key: ValueKey(
                        'operator-${draft.id}-${draft.greater}'
                        '-${draft.conditionError != null}',
                      ),
                      value: draft.greater,
                      hint: 'Chọn điều kiện',
                      errorText: draft.conditionError,
                      options: const [
                        AppDropdownOption(
                          value: false,
                          label: 'Dưới ngưỡng (<)',
                        ),
                        AppDropdownOption(
                          value: true,
                          label: 'Vượt ngưỡng (>)',
                        ),
                      ],
                      enabled: !locked,
                      onChanged: (value) =>
                          setState(() => draft.greater = value),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AppTextField(
                  label: 'Giá trị ngưỡng',
                  controller: draft.threshold,
                  hint: 'Nhập giá trị',
                  enabled: !locked,
                  errorText: draft.thresholdError,
                  onChanged: (_) {
                    if (draft.showErrors) setState(() {});
                  },
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Điền đủ thông tin rồi gạt công tắc để áp dụng; tắt công tắc để '
            'chỉnh sửa.',
            style: AppTextStyles.caption,
          ),
        ],
      ),
    );
  }

  Widget _addConditionButton(int count) {
    final label = 'Thêm điều kiện ($count/$_maxConditions)';
    if (count >= _maxConditions) {
      return GhostButton(label: label, onPressed: null);
    }
    return OutlineAppButton(
      label: label,
      icon: Icons.add,
      onPressed: _load.enabled ? _addCondition : null,
    );
  }

  /// Small pill beside the delay label that flips between "bật" and "tắt".
  Widget _delayModeSwitch() => InkWell(
    borderRadius: BorderRadius.circular(999),
    onTap: _load.delayActive
        ? null
        : () => setState(() => _turnOnFirst = !_turnOnFirst),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.mintButton,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.swap_horiz_rounded,
            size: 16,
            color: AppColors.primary,
          ),
          const SizedBox(width: 4),
          Text(
            _turnOnFirst ? 'Đổi sang tắt' : 'Đổi sang bật',
            style: AppTextStyles.chip.copyWith(color: AppColors.primary),
          ),
        ],
      ),
    ),
  );

  /// While a delay runs the "send" button becomes one red button: icon and
  /// "Dừng - countdown trước khi bật/tắt" centred together.
  Widget _delayStopRow() => FilledButton(
    style: FilledButton.styleFrom(
      backgroundColor: AppColors.danger,
      foregroundColor: Colors.white,
      minimumSize: const Size.fromHeight(54),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    onPressed: _stopDelay,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.stop_rounded, size: 22),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            'Dừng - ${_load.delayCountdown} trước khi '
            '${_load.delayTargetOn ? 'Bật' : 'Tắt'}',
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.buttonPrimary.copyWith(
              color: Colors.white,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _delayRequest() {
    final running = _load.delayActive;
    final delay = int.tryParse(_delay.text.trim());
    final duration = int.tryParse(_duration.text.trim());
    final delayValid = delay != null && delay >= 1 && delay <= 1440;
    final durationValid = duration != null && duration >= 0 && duration <= 1440;
    final canSend = _load.enabled && delayValid && durationValid;
    final first = _turnOnFirst ? 'BẬT' : 'TẮT';
    final second = _turnOnFirst ? 'tắt' : 'bật';
    final when = delay == null
        ? ''
        : delay == 0
        ? ' · ngay'
        : ' · $delay phút';
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Opacity(
            opacity: running ? 0.48 : 1,
            child: AppTextField(
              label: _turnOnFirst ? 'Thời gian bật' : 'Thời gian tắt',
              labelTrailing: _delayModeSwitch(),
              controller: _delay,
              enabled: !running,
              keyboardType: TextInputType.number,
              hint: 'Nhập số phút',
              helper:
                  'Tải tự ${_turnOnFirst ? 'bật' : 'tắt'} sau thời gian đặt trước.',
            ),
          ),
          const SizedBox(height: 14),
          Opacity(
            opacity: running ? 0.48 : 1,
            child: AppTextField(
              label: _turnOnFirst
                  ? 'Thời gian tắt kể từ khi bật'
                  : 'Thời gian bật kể từ khi tắt',
              controller: _duration,
              enabled: !running,
              keyboardType: TextInputType.number,
              hint: 'Nhập số phút',
              helper:
                  'Tải tự $second sau khoảng thời gian '
                  'đặt trước kể từ khi được ${_turnOnFirst ? 'bật' : 'tắt'}; '
                  '0: không tự $second.',
            ),
          ),
          const SizedBox(height: 14),
          if (running)
            _delayStopRow()
          else
            PrimaryButton(
              label: 'Bắt đầu hẹn giờ $first$when',
              icon: Icons.send_rounded,
              onPressed: canSend ? _sendDelay : null,
            ),
        ],
      ),
    );
  }

  /// Immediate on/off request; independent of the delay settings below.
  Widget _requestChoice(String label, bool turnOn) {
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(54)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
    final VoidCallback? onTap = !_load.enabled
        ? null
        : () => _setStateOnDevice(turnOn);
    final selected = _load.stateKnown && _load.isOn == turnOn;
    return Expanded(
      child: selected
          ? FilledButton(style: style, onPressed: onTap, child: Text(label))
          : OutlinedButton(style: style, onPressed: onTap, child: Text(label)),
    );
  }

  Widget _stateChip() {
    final text = !_load.stateKnown
        ? 'chưa rõ'
        : _load.isOn
        ? 'BẬT'
        : 'TẮT';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text('Trạng thái thực tế: $text', style: AppTextStyles.chip),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _load,
    builder: (context, _) {
      final conditions = _sortedConditions;
      final schedules = _sortedSchedules;
      return ScreenScaffold(
        title: '${_load.name}',
        showBack: true,
        embedInTab: widget.inShell,
        navIndex: widget.inShell ? null : 0,
        onNavTap: widget.inShell ? null : (i) => AppRoutes.openTab(context, i),
        titleTrailing: IconButton(
          onPressed: _rename,
          tooltip: 'Đổi tên tải',
          icon: const Icon(Icons.edit_rounded, color: AppColors.primary),
        ),
        headerBottom: _stateChip(),
        headerTrailing: AppMoreMenu<void>(
          itemBuilder: (context) => [
            PopupMenuItem<void>(
              enabled: false,
              child: MenuSwitchRow(
                label: 'Cho phép điều khiển tải',
                value: _load.enabled,
                onChanged: _toggleEnabled,
              ),
            ),
          ],
        ),
        body: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_snapshotLoad == null)
                const AppCard(
                  child: Text(
                    'Chưa nhận được cấu hình tải từ thiết bị. Đợi đồng bộ hoặc '
                    'kiểm tra thiết bị đang trực tuyến.',
                    style: AppTextStyles.bodySecondary,
                  ),
                )
              else if (!_load.enabled)
                const AppCard(
                  child: Text(
                    'Tải này đang bị vô hiệu hóa. Bật "Cho phép điều khiển tải" '
                    'trong menu để sử dụng.',
                    style: AppTextStyles.bodySecondary,
                  ),
                )
              else ...[
                const Text(
                  'Yêu cầu điều khiển mới',
                  style: AppTextStyles.sectionTitle,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _requestChoice('BẬT', true),
                    const SizedBox(width: 12),
                    _requestChoice('TẮT', false),
                  ],
                ),
                const SizedBox(height: 16),
                const Text('Cài đặt trễ', style: AppTextStyles.sectionTitle),
                const SizedBox(height: 10),
                _delayRequest(),
                const SizedBox(height: 20),
                const Text(
                  'Cài đặt điều kiện',
                  style: AppTextStyles.sectionTitle,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Tối đa $_maxConditions điều kiện. Điều kiện cảm biến được '
                  'ưu tiên hơn lịch hẹn khi cùng bật.',
                  style: AppTextStyles.caption,
                ),
                const SizedBox(height: 8),
                for (final draft in conditions) ...[
                  _conditionCard(draft),
                  const SizedBox(height: 12),
                ],
                _addConditionButton(conditions.length),
                const SizedBox(height: 20),
                const Text('Lịch hẹn', style: AppTextStyles.sectionTitle),
                const SizedBox(height: 4),
                const Text(
                  'Tối đa $_maxSchedules lịch hẹn',
                  style: AppTextStyles.caption,
                ),
                const SizedBox(height: 8),
                for (final draft in schedules) ...[
                  _scheduleCard(draft),
                  const SizedBox(height: 12),
                ],
                _addScheduleButton(),
              ],
            ],
          ),
        ),
      );
    },
  );
}
