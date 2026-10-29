import '../state/load_controller.dart';
import 'device_selection.dart';

class LoadControlSelection {
  const LoadControlSelection({required this.device, required this.load});

  final DeviceSelection device;
  final LoadController load;
}
