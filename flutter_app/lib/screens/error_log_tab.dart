import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../protocol/device_log.dart';
import '../services/device_error_log.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_card.dart';
import 'diagnostics_screen.dart' show formatUptime;

const _errorColor = Color(0xFFFF9C92);
const _warningColor = Color(0xFFFFD27A);

/// Tab "Nhật ký lỗi": the warnings and errors the ESP32 stored in flash,
/// newest first. Loads when it opens and again on "Tải lại".
class ErrorLogTab extends StatefulWidget {
  const ErrorLogTab({
    super.key,
    required this.deviceId,
    this.service,
    this.autoLoad = true,
  });

  final String deviceId;

  /// Loads the log when the tab opens; tests turn it off.
  final bool autoLoad;

  /// The app-wide reader unless a test gives its own.
  final DeviceErrorLog? service;

  @override
  State<ErrorLogTab> createState() => _ErrorLogTabState();
}

class _ErrorLogTabState extends State<ErrorLogTab> {
  DeviceErrorLog get _service => widget.service ?? DeviceErrorLog.instance;

  @override
  void initState() {
    super.initState();
    if (!widget.autoLoad) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_service.load(widget.deviceId));
    });
  }

  Future<void> _copy(List<DeviceLogEntry> newestFirst) async {
    await Clipboard.setData(
      ClipboardData(
        text: [
          for (final e in newestFirst.reversed)
            '#${e.seq} boot=${e.boot} ${e.level} ${_timeText(e)} ${e.message}',
        ].join('\n'),
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Đã sao chép nhật ký lỗi')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final id = widget.deviceId;
        final status = _service.statusOf(id);
        final loading = status == DeviceErrorLogStatus.loading;
        final entries = _service.entriesOf(id).reversed.toList();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Nhật ký lỗi lưu trong bộ nhớ thiết bị',
                      style: AppTextStyles.heading,
                    ),
                    const SizedBox(height: 6),
                    if (loading) ...[
                      Text(
                        'Đang tải… ${entries.length} dòng',
                        style: AppTextStyles.bodySecondary,
                      ),
                      const SizedBox(height: 8),
                      const LinearProgressIndicator(),
                    ] else if (status == DeviceErrorLogStatus.failed)
                      Text(
                        _service.errorOf(id) ?? 'Không đọc được nhật ký lỗi.',
                        style: AppTextStyles.bodySecondary.copyWith(
                          color: AppColors.danger,
                        ),
                      )
                    else
                      Text(
                        '${entries.length} dòng'
                        '${_service.isTruncated(id) ? ' (chưa đủ, bản ghi quá dài)' : ''}',
                        style: AppTextStyles.bodySecondary,
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: loading
                              ? null
                              : () => unawaited(_service.load(id)),
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('Tải lại'),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: entries.isEmpty
                              ? null
                              : () => unawaited(_copy(entries)),
                          icon: const Icon(Icons.copy_rounded, size: 18),
                          label: const Text('Sao chép'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _LogPanel(entries: entries, loading: loading),
              ),
              const SizedBox(height: 8),
              const Text(
                'Chỉ đọc được khi thiết bị trực tuyến. Địa chỉ crash (pc, bt) '
                'cần file ELF đúng phiên bản firmware để giải mã.',
                style: AppTextStyles.bodySecondary,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.entries, required this.loading});

  final List<DeviceLogEntry> entries;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.console,
        borderRadius: BorderRadius.circular(18),
      ),
      child: entries.isEmpty
          ? Center(
              child: Text(
                loading ? 'Đang đọc nhật ký…' : 'Chưa có dòng nhật ký nào',
                style: AppTextStyles.consoleSub,
              ),
            )
          : ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, index) => _LogRow(entry: entries[index]),
            ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry});

  final DeviceLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final color = entry.isError
        ? _errorColor
        : entry.isWarning
        ? _warningColor
        : null;
    final label = switch (entry.level) {
      'E' => 'LỖI',
      'W' => 'CẢNH BÁO',
      _ => 'THÔNG TIN',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_timeText(entry)} · $label · lần chạy #${entry.boot}',
            style: AppTextStyles.consoleMeta.copyWith(color: color),
          ),
          const SizedBox(height: 2),
          Text(
            entry.message,
            style: AppTextStyles.consoleBody.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// Wall-clock time when the ESP32 knew it, else the time since its boot.
String _timeText(DeviceLogEntry entry) {
  final ts = entry.timestampMs;
  if (ts == null) return '+${formatUptime(entry.uptimeMs)}';
  final t = DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.day)}/${two(t.month)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}
