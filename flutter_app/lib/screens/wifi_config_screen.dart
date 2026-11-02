import 'package:flutter/material.dart';

import '../core/error_text.dart';
import '../models/provision_success_args.dart';
import '../models/provision_failure_args.dart';
import '../models/scanned_device.dart';
import '../models/wifi_network.dart';
import '../navigation/app_routes.dart';
import '../protocol/validators.dart';
import '../protocol/network_interfaces.dart';
import '../protocol/wifi_scan_messages.dart';
import '../services/auth_service.dart';
import '../services/ble_prov_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_buttons.dart';
import '../widgets/app_text_field.dart';
import '../widgets/screen_scaffold.dart';

class WifiConfigArgs {
  const WifiConfigArgs({required this.device, required this.client});

  final ScannedDevice device;
  final BleProvisioningService client;
}

class WifiConfigScreen extends StatefulWidget {
  const WifiConfigScreen({super.key, required this.args});

  final WifiConfigArgs args;

  @override
  State<WifiConfigScreen> createState() => _WifiConfigScreenState();
}

class _WifiConfigScreenState extends State<WifiConfigScreen> {
  final _pass = TextEditingController();
  bool _ethernetOnly = false;
  bool _cellularOnly = false;
  bool _loadingInterfaces = true;
  NetworkInterfaces? _interfaces;
  String? _interfaceError;
  bool _showPassword = false;
  bool _scanning = false;
  bool _sending = false;
  String? _scanError;
  List<WifiNetwork> _networks = const [];
  WifiNetwork? _selected;

  BleProvisioningService get _client => widget.args.client;

  bool get _canSend =>
      !_sending &&
      !_loadingInterfaces &&
      _interfaces != null &&
      (_ethernetOnly ||
          _cellularOnly ||
          (!_scanning &&
              _selected != null &&
              WifiPasswordRule.isValid(_pass.text)));

  @override
  void initState() {
    super.initState();
    _pass.addListener(() => setState(() {}));
    _loadInterfaces();
  }

  @override
  void dispose() {
    _pass.dispose();
    _client.close();
    super.dispose();
  }

  Future<void> _loadInterfaces() async {
    setState(() {
      _loadingInterfaces = true;
      _interfaceError = null;
    });
    try {
      final interfaces = await _client.readNetworkInterfaces();
      if (!mounted) return;
      setState(() {
        _interfaces = interfaces;
        _loadingInterfaces = false;
        _ethernetOnly = !interfaces.wifi && interfaces.ethernet;
        _cellularOnly = !interfaces.wifi && interfaces.cellular;
      });
      if (interfaces.wifi) await _scan();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingInterfaces = false;
        _interfaceError = userErrorText(
          'Không đọc được khả năng mạng từ thiết bị. Kiểm tra firmware và thử lại.',
          error,
        );
      });
    }
  }

  Future<void> _scan() async {
    if (_scanning ||
        _ethernetOnly ||
        _cellularOnly ||
        _interfaces?.wifi != true) {
      return;
    }
    setState(() {
      _scanning = true;
      _scanError = null;
      _selected = null;
      _pass.clear();
    });
    try {
      final result = WifiNetwork.selectable(await _client.scanWifi());
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _networks = result;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _scanError = e is WifiScanException && e.code == 'wifi_unavailable'
            ? userErrorText('Wi-Fi không khả dụng trên thiết bị', e)
            : userErrorText('Không quét được Wi-Fi', e);
      });
    }
  }

  void _setEthernetOnly(bool value) {
    setState(() {
      _ethernetOnly = value;
      _selected = null;
      _pass.clear();
    });
    if (!value) _scan();
  }

  void _setCellularOnly(bool value) {
    setState(() {
      _cellularOnly = value;
      _selected = null;
      _pass.clear();
    });
    if (!value) _scan();
  }

  Future<void> _send() async {
    if (!_canSend) return;
    setState(() => _sending = true);
    try {
      final userId = AuthService.requireUserId();
      final result = await _client.sendConfig(
        ssid: _ethernetOnly || _cellularOnly ? '' : _selected!.ssid,
        password: _ethernetOnly || _cellularOnly ? '' : _pass.text,
        userId: userId,
        onlyUseEthernet: _ethernetOnly,
        onlyUse4g: _cellularOnly,
      );
      await _client.close();
      if (!mounted) return;
      setState(() => _sending = false);
      Navigator.of(context).pushNamed(
        AppRoutes.provisionSuccess,
        arguments: ProvisionSuccessArgs(
          userId: userId,
          deviceId: result.deviceId,
          deviceName: widget.args.device.name,
          result: result,
          onlyUseEthernet: _ethernetOnly,
          onlyUse4g: _cellularOnly,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      await Navigator.of(context).pushNamed(
        AppRoutes.provisionFailure,
        arguments: ProvisionFailureArgs(
          deviceName: widget.args.device.name,
          message: userErrorText('Không gửi được cấu hình mạng', e),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      title: 'Cấu hình mạng',
      showBack: true,
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Kết nối mạng cho thiết bị',
              style: AppTextStyles.heading,
            ),
            const SizedBox(height: 8),
            Text(
              _interfaces == null
                  ? 'Đọc khả năng mạng của thiết bị qua BLE trước khi cấu hình.'
                  : 'Thiết bị hỗ trợ: ${[if (_interfaces!.wifi) 'Wi-Fi', if (_interfaces!.ethernet) 'Ethernet', if (_interfaces!.cellular) '4G'].join(' và ')}.',
              style: AppTextStyles.bodySecondary,
            ),
            const SizedBox(height: 20),
            if (_loadingInterfaces)
              const Center(child: CircularProgressIndicator())
            else if (_interfaceError != null) ...[
              Text(_interfaceError!, style: AppTextStyles.bodySecondary),
              TextButton(
                onPressed: _loadInterfaces,
                child: const Text('Thử đọc lại khả năng mạng'),
              ),
            ],
            if (_interfaces != null) ...[
              const Text(
                'Lựa chọn phương thức kết nối',
                style: AppTextStyles.label,
              ),
              const SizedBox(height: 8),
              if (_interfaces!.ethernet)
                Row(
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: _ethernetOnly,
                        onChanged: _sending || !_interfaces!.wifi
                            ? null
                            : (v) => _setEthernetOnly(v ?? false),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Chỉ sử dụng Ethernet',
                      style: AppTextStyles.body,
                    ),
                  ],
                ),
              if (_interfaces!.cellular)
                Row(
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: _cellularOnly,
                        onChanged: _sending || !_interfaces!.wifi
                            ? null
                            : (v) => _setCellularOnly(v ?? false),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('Chỉ sử dụng 4G', style: AppTextStyles.body),
                  ],
                ),
              if (_cellularOnly) ...[
                const SizedBox(height: 8),
                const Text(
                  'Kết nối 4G cần firmware có driver modem tương ứng.',
                  style: AppTextStyles.bodySecondary,
                ),
              ],
              if (_interfaces!.wifi && !_ethernetOnly && !_cellularOnly) ...[
                const SizedBox(height: 18),
                _networkHeader(),
                ..._networkSection(),
              ],
            ],
            const SizedBox(height: 24),
            PrimaryButton(
              label: _sending ? 'Đang gửi...' : 'Lưu cấu hình',
              icon: Icons.send_rounded,
              enabled: _canSend,
              onPressed: _send,
            ),
          ],
        ),
      ),
    );
  }

  Widget _networkHeader() {
    return Row(
      children: [
        const Expanded(
          child: Text('Mạng khả dụng', style: AppTextStyles.label),
        ),
        TextButton.icon(
          onPressed: _scanning || _sending ? null : _scan,
          icon: _scanning
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.wifi_find_rounded, size: 18),
          label: Text(_scanning ? 'Đang quét...' : 'Quét Wi-Fi'),
        ),
      ],
    );
  }

  List<Widget> _networkSection() {
    if (_scanError != null) {
      return [
        const SizedBox(height: 8),
        Text(
          _scanError!,
          style: AppTextStyles.bodySecondary.copyWith(
            color: AppColors.errorText,
          ),
        ),
      ];
    }
    if (_networks.isEmpty) {
      return [
        const SizedBox(height: 8),
        Text(
          _scanning
              ? 'Đang quét mạng Wi-Fi...'
              : 'Không tìm thấy mạng Wi-Fi có bảo mật.',
          style: AppTextStyles.bodySecondary,
        ),
      ];
    }
    return [
      const SizedBox(height: 8),
      Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            for (var i = 0; i < _networks.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: AppColors.divider),
              _networkTile(_networks[i]),
            ],
          ],
        ),
      ),
    ];
  }

  Widget _networkTile(WifiNetwork n) {
    final selected = _selected == n;
    return Column(
      children: [
        ListTile(
          dense: true,
          leading: Icon(
            Icons.wifi_rounded,
            color: n.rssi > -70 ? AppColors.primary : AppColors.textMuted,
          ),
          title: Text(n.ssid, style: AppTextStyles.body),
          subtitle: Text('${n.rssi} dBm', style: AppTextStyles.bodySecondary),
          trailing: const Icon(
            Icons.lock_outline_rounded,
            size: 18,
            color: AppColors.textSecondary,
          ),
          selected: selected,
          onTap: _sending
              ? null
              : () => setState(() {
                  _selected = n;
                  _pass.clear();
                }),
        ),
        if (selected)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: AppTextField(
              label: 'Mật khẩu "${n.ssid}"',
              controller: _pass,
              obscureText: !_showPassword,
              suffixIcon: IconButton(
                tooltip: _showPassword ? 'Ẩn mật khẩu' : 'Hiện mật khẩu',
                icon: Icon(
                  _showPassword
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                ),
                onPressed: () => setState(() => _showPassword = !_showPassword),
              ),
              helper:
                  WifiPasswordRule.error(_pass.text) ??
                  'Từ ${WifiPasswordRule.minLength} đến ${WifiPasswordRule.maxLength} ký tự',
            ),
          ),
      ],
    );
  }
}
