import 'dart:async';

import 'package:flutter/material.dart';

import '../navigation/app_routes.dart';
import '../services/device_repository.dart';
import '../services/mqtt_session_manager.dart';
import '../state/device_presence.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_card.dart';
import '../widgets/screen_scaffold.dart';
import '../widgets/status_chip.dart';
import 'console_screen.dart' show ConsoleArgs;
import 'diagnostics_screen.dart' show presenceChip;

/// Developer console entry: the devices of the account, each opening the live
/// MQTT log of that device.
class TechLogScreen extends StatefulWidget {
  const TechLogScreen({super.key, this.inShell = true});

  final bool inShell;

  @override
  State<TechLogScreen> createState() => _TechLogScreenState();
}

class _TechLogScreenState extends State<TechLogScreen> {
  final _repository = DeviceRepository.instance;

  @override
  void initState() {
    super.initState();
    DevicePresence.instance.start();
    unawaited(_repository.refresh());
  }

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      title: 'Nhật ký kỹ thuật',
      showBack: true,
      embedInTab: widget.inShell,
      navIndex: widget.inShell ? null : 1,
      onNavTap: widget.inShell ? null : (i) => AppRoutes.openTab(context, i),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          _repository,
          MqttSessionManager.instance,
          DevicePresence.instance,
        ]),
        builder: (context, _) {
          final devices = _repository.devices;
          return RefreshIndicator(
            onRefresh: _repository.refresh,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Thiết bị', style: AppTextStyles.sectionTitle),
                  const SizedBox(height: 4),
                  const Text(
                    'Chọn thiết bị để mở console realtime.',
                    style: AppTextStyles.bodySecondary,
                  ),
                  if (devices.isEmpty) ...[
                    const SizedBox(height: 12),
                    AppCard(
                      child: Text(
                        _repository.isLoading
                            ? 'Đang tải danh sách thiết bị...'
                            : 'Chưa có thiết bị nào được đăng ký.',
                        style: AppTextStyles.bodySecondary,
                      ),
                    ),
                  ],
                  for (final device in devices) ...[
                    const SizedBox(height: 12),
                    Builder(
                      builder: (context) {
                        final (label, kind) = presenceChip(
                          connected: MqttSessionManager.instance.isConnected,
                          online: DevicePresence.instance.isOnline(
                            device.macAddress,
                          ),
                        );
                        return _DeviceLogCard(
                          name: device.name,
                          deviceId: device.macAddress,
                          chipLabel: label,
                          kind: kind,
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DeviceLogCard extends StatelessWidget {
  const _DeviceLogCard({
    required this.name,
    required this.deviceId,
    required this.chipLabel,
    required this.kind,
  });

  final String name;
  final String deviceId;
  final String chipLabel;
  final StatusKind kind;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).pushNamed(
        AppRoutes.console,
        arguments: ConsoleArgs(name: name, deviceId: deviceId),
      ),
      child: AppCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(name, style: AppTextStyles.cardTitle),
                      ),
                      const SizedBox(width: 8),
                      StatusChip(label: chipLabel, kind: kind),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('device_id: $deviceId', style: AppTextStyles.monoCaption),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_forward_rounded,
              color: AppColors.primary,
              size: 22,
            ),
          ],
        ),
      ),
    );
  }
}
