import '../protocol/provisioning_messages.dart';

class ProvisionSuccessArgs {
  const ProvisionSuccessArgs({
    required this.userId,
    required this.deviceId,
    required this.deviceName,
    required this.result,
    required this.onlyUseEthernet,
    this.onlyUse4g = false,
  });

  final String userId;
  final String deviceId;
  final String deviceName;
  final ProvisioningStatus result;
  final bool onlyUseEthernet;
  final bool onlyUse4g;
}
