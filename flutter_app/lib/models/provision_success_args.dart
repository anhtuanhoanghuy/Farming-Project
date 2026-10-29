import '../protocol/provisioning_messages.dart';

class ProvisionSuccessArgs {
  const ProvisionSuccessArgs({
    required this.userId,
    required this.deviceId,
    required this.deviceName,
    required this.result,
    required this.onlyUseEthernet,
  });

  final String userId;
  final String deviceId;
  final String deviceName;
  final ProvisioningStatus result;
  final bool onlyUseEthernet;
}
