import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/scanned_device.dart';

enum BleScanStatus { ready, unsupported, bluetoothOff, error }

/// Scans for provisioning-mode controllers and keeps only those advertising the provisioning service UUID.
class BleScanController extends ChangeNotifier {
  static const _scanTimeout = Duration(seconds: 30);
  static const _goneAfter = Duration(seconds: 6);

  BleScanStatus _status = BleScanStatus.ready;
  bool _scanning = false;
  String? _error;
  List<ScannedDevice> _devices = const [];

  StreamSubscription<List<ScanResult>>? _resultsSub;
  StreamSubscription<bool>? _scanningSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

  BleScanStatus get status => _status;
  bool get scanning => _scanning;
  String? get error => _error;
  List<ScannedDevice> get devices => _devices;

  Future<void> start() async {
    _error = null;
    if (!await FlutterBluePlus.isSupported) {
      _setStatus(BleScanStatus.unsupported);
      return;
    }

    _resultsSub ??= FlutterBluePlus.onScanResults.listen(_onResults);
    _scanningSub ??= FlutterBluePlus.isScanning.listen((v) {
      _scanning = v;
      notifyListeners();
    });
    _adapterSub ??= FlutterBluePlus.adapterState.listen(_onAdapterState);

    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {
        // User declined or platform cannot turn on; fall through to the check below.
      }
    }
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      _setStatus(BleScanStatus.bluetoothOff);
      return;
    }

    try {
      _setStatus(BleScanStatus.ready);
      await FlutterBluePlus.startScan(
        withServices: [Guid(ScannedDevice.serviceUuid)],
        timeout: _scanTimeout,
        continuousUpdates: true,
        removeIfGone: _goneAfter,
      );
    } catch (e) {
      _error = e.toString();
      _setStatus(BleScanStatus.error);
    }
  }

  Future<void> stop() async {
    if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
  }

  void _onAdapterState(BluetoothAdapterState state) {
    if (state == BluetoothAdapterState.on) {
      if (_status == BleScanStatus.bluetoothOff) start();
    } else if (state == BluetoothAdapterState.off) {
      _devices = const [];
      _setStatus(BleScanStatus.bluetoothOff);
    }
  }

  void _onResults(List<ScanResult> results) {
    final service = Guid(ScannedDevice.serviceUuid);
    final found = <ScannedDevice>[];
    for (final r in results) {
      if (!r.advertisementData.serviceUuids.contains(service)) continue;
      final name = r.advertisementData.advName.isNotEmpty
          ? r.advertisementData.advName
          : r.device.platformName;
      found.add(ScannedDevice(
        id: r.device.remoteId.str,
        name: name.isNotEmpty ? name : 'Thiết bị mới',
        rssi: r.rssi,
      ));
    }
    found.sort((a, b) => b.rssi.compareTo(a.rssi));
    _devices = found;
    notifyListeners();
  }

  void _setStatus(BleScanStatus s) {
    _status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _resultsSub?.cancel();
    _scanningSub?.cancel();
    _adapterSub?.cancel();
    if (FlutterBluePlus.isScanningNow) FlutterBluePlus.stopScan();
    super.dispose();
  }
}
