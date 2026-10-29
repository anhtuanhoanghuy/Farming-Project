import 'package:flutter/material.dart';

import '../core/error_text.dart';
import '../models/scanned_device.dart';
import '../navigation/app_routes.dart';
import '../screens/wifi_config_screen.dart';
import '../services/ble_prov_service.dart';
import '../services/ble_scan_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_buttons.dart';
import '../widgets/app_card.dart';
import '../widgets/screen_scaffold.dart';

class BleScanScreen extends StatefulWidget {
  const BleScanScreen({super.key});

  @override
  State<BleScanScreen> createState() => _BleScanScreenState();
}

class _BleScanScreenState extends State<BleScanScreen> {
  final _scan = BleScanController();
  String? _connectingId;

  @override
  void initState() {
    super.initState();
    _scan.start();
  }

  @override
  void dispose() {
    _scan.dispose();
    super.dispose();
  }

  Future<void> _select(ScannedDevice device) async {
    if (_connectingId != null) return;
    setState(() => _connectingId = device.id);
    await _scan.stop();
    try {
      final client = await BleProvisioningService.connect(device);
      if (!mounted) {
        await client.close();
        return;
      }
      setState(() => _connectingId = null);
      await Navigator.of(context).pushNamed(
        AppRoutes.wifiConfig,
        arguments: WifiConfigArgs(device: device, client: client),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _connectingId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userErrorText('Không thể kết nối ${device.name}', e),
          ),
        ),
      );
    }
    if (mounted) _scan.start();
  }

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      showMore: false,
      title: 'Tìm thiết bị mới',
      showBack: true,
      body: ListenableBuilder(
        listenable: _scan,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StatusCard(scan: _scan),
              const SizedBox(height: 22),
              const Text(
                'Thiết bị khả dụng',
                style: AppTextStyles.sectionTitle,
              ),
              const SizedBox(height: 12),
              if (_scan.devices.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    _scan.scanning
                        ? 'Chưa thấy thiết bị hợp lệ nào.'
                        : 'Không tìm thấy thiết bị hợp lệ.',
                    style: AppTextStyles.bodySecondary,
                  ),
                ),
              for (final d in _scan.devices) ...[
                _BleDeviceCard(
                  device: d,
                  connecting: _connectingId == d.id,
                  enabled: _connectingId == null,
                  onSelect: () => _select(d),
                ),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 4),
              OutlineAppButton(
                label: _scan.scanning ? 'Đang quét...' : 'Quét lại',
                icon: Icons.refresh_rounded,
                onPressed: _scan.scanning ? null : _scan.start,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.scan});

  final BleScanController scan;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String title, String message, bool problem) =
        switch (scan.status) {
      BleScanStatus.unsupported => (
          Icons.bluetooth_disabled,
          'Thiết bị không hỗ trợ BLE',
          'Điện thoại này không có Bluetooth Low Energy.',
          true,
        ),
      BleScanStatus.bluetoothOff => (
          Icons.bluetooth_disabled,
          'Bluetooth đang tắt',
          'Bật Bluetooth để quét thiết bị.',
          true,
        ),
      BleScanStatus.error => (
          Icons.error_outline,
          'Không thể quét Bluetooth', 'Kiểm tra quyền Bluetooth/Vị trí rồi thử lại.',
          true,
        ),
      BleScanStatus.ready => (
          Icons.bluetooth,
          scan.scanning ? 'Đang tìm kiếm thiết bị...' : 'Đã dừng quét',
          'Đặt điện thoại gần bộ điều khiển.',
          false,
        ),
    };

    return AppCard(
      color: problem ? AppColors.errorBg : AppColors.mint,
      borderColor: problem ? AppColors.errorSoft : AppColors.primarySoft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                color: problem ? AppColors.errorText : AppColors.primary,
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: AppTextStyles.cardTitle)),
              if (scan.scanning && !problem)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(message, style: AppTextStyles.bodySecondary),
        ],
      ),
    );
  }
}

class _BleDeviceCard extends StatelessWidget {
  const _BleDeviceCard({
    required this.device,
    required this.connecting,
    required this.enabled,
    required this.onSelect,
  });

  final ScannedDevice device;
  final bool connecting;
  final bool enabled;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(device.name, style: AppTextStyles.cardTitle),
          const SizedBox(height: 12),
          Row(
            children: [
              const Expanded(
                child: Text('Tín hiệu BLE', style: AppTextStyles.bodySecondary),
              ),
              Text(
                '${device.rssi} dBm · ${device.proximity}',
                style: AppTextStyles.bodySecondary,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Expanded(
                child: Text('MAC rút gọn', style: AppTextStyles.bodySecondary),
              ),
              Text(device.shortMac, style: AppTextStyles.bodySecondary),
            ],
          ),
          const SizedBox(height: 14),
          OutlineAppButton(
            label: connecting ? 'Đang kết nối...' : 'Chọn thiết bị',
            height: 46,
            onPressed: enabled ? onSelect : null,
          ),
        ],
      ),
    );
  }
}
