import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../navigation/app_routes.dart';
import '../services/mqtt_session_manager.dart';
import '../services/traffic_log.dart';
import '../state/device_presence.dart';
import '../state/device_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_card.dart';
import '../widgets/screen_scaffold.dart';
import '../widgets/status_chip.dart';
import 'diagnostics_screen.dart' show presenceChip;

class ConsoleArgs {
  const ConsoleArgs({required this.name, required this.deviceId});

  final String name;
  final String deviceId;
}

/// Entries shown at once; older ones stay in [TrafficLog] but are not drawn.
const _maxRows = 300;

class ConsoleScreen extends StatefulWidget {
  const ConsoleScreen({super.key, this.inShell = true, this.args});

  final bool inShell;
  final ConsoleArgs? args;

  @override
  State<ConsoleScreen> createState() => _ConsoleScreenState();
}

class _ConsoleScreenState extends State<ConsoleScreen> {
  final _log = TrafficLog.instance;
  final _scroll = ScrollController();
  final _activeFilters = <String>{};
  bool _autoScroll = true;
  int? _selectedId;
  int _lastCount = 0;

  /// The entries as they were when "Tạm dừng" was pressed; null while live.
  List<TrafficEntry>? _frozen;

  String get _deviceId => widget.args?.deviceId ?? '';
  String get _name => widget.args?.name ?? _deviceId;

  @override
  void initState() {
    super.initState();
    DevicePresence.instance.start();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<TrafficEntry> _visible() {
    final source = _frozen ?? _log.entriesOf(_deviceId);
    final filtered = _activeFilters.isEmpty
        ? source
        : [
            for (final e in source)
              if (_activeFilters.contains(e.type)) e,
          ];
    return filtered.length > _maxRows
        ? filtered.sublist(filtered.length - _maxRows)
        : filtered;
  }

  void _toggleFilter(String tag) {
    setState(() {
      if (!_activeFilters.remove(tag)) _activeFilters.add(tag);
    });
  }

  void _togglePause() {
    setState(() {
      _frozen = _frozen == null ? _log.entriesOf(_deviceId) : null;
    });
  }

  void _clear() {
    _log.clear(_deviceId);
    setState(() {
      if (_frozen != null) _frozen = [];
      _selectedId = null;
    });
  }

  /// Keeps the newest entry in view while new ones arrive.
  void _followNewest(int count) {
    if (!_autoScroll || _frozen != null || count == _lastCount) {
      _lastCount = count;
      return;
    }
    _lastCount = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      title: 'Console realtime',
      showBack: true,
      embedInTab: widget.inShell,
      navIndex: widget.inShell ? null : 1,
      onNavTap: widget.inShell ? null : (i) => AppRoutes.openTab(context, i),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          _log,
          DevicePresence.instance,
          MqttSessionManager.instance,
          DeviceState.instance,
        ]),
        builder: (context, _) {
          final visible = _visible();
          _followNewest(visible.length);
          final selected = visible
              .where((e) => e.id == _selectedId)
              .firstOrNull;
          return SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DeviceInfoCard(name: _name, deviceId: _deviceId),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _TagChip(
                      label: 'Tất cả',
                      selected: _activeFilters.isEmpty,
                      onTap: () => setState(_activeFilters.clear),
                    ),
                    for (final tag in TrafficLog.types)
                      _TagChip(
                        label: tag,
                        selected: _activeFilters.contains(tag),
                        onTap: () => _toggleFilter(tag),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                _Toolbar(
                  paused: _frozen != null,
                  autoScroll: _autoScroll,
                  onPause: _togglePause,
                  onClear: _clear,
                  onAutoScroll: () =>
                      setState(() => _autoScroll = !_autoScroll),
                ),
                const SizedBox(height: 12),
                _ConsolePanel(
                  entries: visible,
                  selected: selected,
                  controller: _scroll,
                  paused: _frozen != null,
                  onSelect: (e) => setState(() => _selectedId = e.id),
                ),
                if (selected != null) ...[
                  const SizedBox(height: 12),
                  _DetailCard(entry: selected),
                ],
                const SizedBox(height: 12),
                const Text(
                  'Hiển thị các bản tin MQTT app gửi và nhận trong phiên này '
                  '(tối đa 600 mục, telemetry giữ 120 mục gần nhất)',
                  style: AppTextStyles.bodySecondary,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DeviceInfoCard extends StatelessWidget {
  const _DeviceInfoCard({required this.name, required this.deviceId});

  final String name;
  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final (label, kind) = presenceChip(
      connected: MqttSessionManager.instance.isConnected,
      online: DevicePresence.instance.isOnline(deviceId),
    );
    final net = DeviceState.instance.deviceId == deviceId
        ? DeviceState.instance.internetMethod
        : null;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(name, style: AppTextStyles.heading)),
              StatusChip(label: label, kind: kind),
            ],
          ),
          const SizedBox(height: 10),
          Text('device_id: $deviceId', style: AppTextStyles.mono),
          Text(
            'user_id: ${MqttSessionManager.instance.userId ?? '-'}',
            style: AppTextStyles.mono,
          ),
          const SizedBox(height: 8),
          Text(
            'Mạng: ${switch (net) {
              'WIFI' => 'Wi-Fi',
              'ETH' => 'Ethernet',
              _ => 'chưa rõ',
            }}',
            style: AppTextStyles.bodySecondary,
          ),
        ],
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.chipNeutral,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Text(
          label,
          style: AppTextStyles.bodyMedium.copyWith(
            color: selected
                ? AppColors.textOnPrimary
                : AppColors.chipNeutralText,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.paused,
    required this.autoScroll,
    required this.onPause,
    required this.onClear,
    required this.onAutoScroll,
  });

  final bool paused;
  final bool autoScroll;
  final VoidCallback onPause;
  final VoidCallback onClear;
  final VoidCallback onAutoScroll;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Nút Tạm dừng / Tiếp tục chiếm không gian linh hoạt
        Expanded(
          flex: 2, // Cho phần này rộng hơn một chút nếu nhãn dài
          child: OutlinedButton.icon(
            onPressed: onPause,
            icon: Icon(
              paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
              size: 20,
            ),
            label: Text(
              paused ? 'Tiếp tục' : 'Tạm dừng',
              style: AppTextStyles.buttonPrimary,
              overflow: TextOverflow.ellipsis,
            ),
            style: OutlinedButton.styleFrom(
              backgroundColor: AppColors.surface,
              foregroundColor: AppColors.primary,
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              side: const BorderSide(color: AppColors.border),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Nút Xóa
        Expanded(
          child: TextButton.icon(
            onPressed: onClear,
            icon: const Icon(
              Icons.delete_rounded,
              size: 20,
              color: AppColors.danger,
            ),
            label: Text(
              'Xóa',
              style: AppTextStyles.buttonPrimary.copyWith(
                color: AppColors.danger,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
          ),
        ),
        const SizedBox(width: 4),
        // Nút Tự cuộn
        Expanded(
          flex: 2,
          child: TextButton.icon(
            onPressed: onAutoScroll,
            icon: Icon(
              autoScroll
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 20,
            ),
            label: const Text(
              'Tự cuộn',
              style: AppTextStyles.buttonPrimary,
              overflow: TextOverflow.ellipsis,
            ),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.primary,
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
          ),
        ),
      ],
    );
  }
}

class _ConsolePanel extends StatelessWidget {
  const _ConsolePanel({
    required this.entries,
    required this.selected,
    required this.controller,
    required this.paused,
    required this.onSelect,
  });

  final List<TrafficEntry> entries;
  final TrafficEntry? selected;
  final ScrollController controller;
  final bool paused;
  final ValueChanged<TrafficEntry> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.console,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  paused ? 'MQTT · ĐANG TẠM DỪNG' : 'MQTT · TRỰC TIẾP',
                  style: AppTextStyles.consoleTitle,
                ),
              ),
              Text('${entries.length} mục', style: AppTextStyles.consoleSub),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(height: 1, color: AppColors.consoleDivider),
          const SizedBox(height: 6),
          SizedBox(
            height: 420,
            child: entries.isEmpty
                ? const Center(
                    child: Text(
                      'Chưa có bản tin nào',
                      style: AppTextStyles.consoleSub,
                    ),
                  )
                : ListView.builder(
                    controller: controller,
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return _ConsoleRow(
                        entry: entry,
                        selected: entry.id == selected?.id,
                        onTap: () => onSelect(entry),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ConsoleRow extends StatelessWidget {
  const _ConsoleRow({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final TrafficEntry entry;
  final bool selected;
  final VoidCallback onTap;

  String get _topicHint => 'v1/…/${entry.topic.split('/').last}';

  @override
  Widget build(BuildContext context) {
    final failed = entry.type == 'ACK' && entry.summary.contains('LỖI');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: selected ? AppColors.consoleSelected : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: double.infinity,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.header, style: AppTextStyles.consoleMeta),
                  const SizedBox(height: 2),
                  Text(_topicHint, style: AppTextStyles.consoleSub),
                  const SizedBox(height: 2),
                  Text(
                    entry.summary,
                    style: AppTextStyles.consoleBody.copyWith(
                      color: failed ? const Color(0xFFFF9C92) : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailCard extends StatelessWidget {
  const _DetailCard({required this.entry});

  final TrafficEntry entry;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  'Chi tiết · ${entry.type}',
                  style: AppTextStyles.cardTitle.copyWith(
                    color: AppColors.primary,
                    fontSize: 18,
                  ),
                ),
              ),
              Text(
                '${entry.timeText}  ·  ${entry.direction}',
                style: AppTextStyles.monoCaption,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(entry.topic, style: AppTextStyles.monoCaption),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.console,
              borderRadius: BorderRadius.circular(14),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                entry.prettyPayload,
                style: AppTextStyles.consoleBody,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: entry.prettyPayload),
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Đã sao chép bản tin')),
                  );
                }
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Sao chép'),
            ),
          ),
        ],
      ),
    );
  }
}
