import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/load_sample.dart';

/// BLE UUIDs for the Tindeq Progressor
class TindeqUuids {
  static final service = Guid('7e4e1701-1ea6-40c9-9dcc-13d34ffead57');
  static final data = Guid('7e4e1702-1ea6-40c9-9dcc-13d34ffead57');
  static final controlPoint = Guid('7e4e1703-1ea6-40c9-9dcc-13d34ffead57');
}

/// Command opcodes sent to the Progressor control point
class TindeqCommands {
  static const int tareScale = 100;
  static const int startWeightMeasurement = 101;
  static const int stopWeightMeasurement = 102;
  static const int startPeakRfd = 103;
  static const int startPeakRfdSeries = 104;
  static const int addCalibrationPoint = 105;
  static const int saveCalibration = 106;
  static const int getAppVersion = 107;
  static const int getErrorInfo = 108;
  static const int clearErrorInfo = 109;
  static const int enterSleep = 110;
  static const int getBatteryVoltage = 111;
}

/// Response type codes from the Progressor data characteristic
class TindeqResponse {
  static const int commandResponse = 0;
  static const int weightMeasurement = 1;
  static const int rfdPeak = 2;
  static const int rfdPeakSeries = 3;
  static const int lowPowerWarning = 4;
}

enum TindeqConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
  measuring,
}

class TindeqService {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _dataChar;
  BluetoothCharacteristic? _ctrlChar;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;

  final _loadController = StreamController<LoadSample>.broadcast();
  final _stateController =
      StreamController<TindeqConnectionState>.broadcast();
  final _batteryController = StreamController<double>.broadcast();
  final _peakLoadController = StreamController<double>.broadcast();
  final _logController = StreamController<String>.broadcast();

  Stream<LoadSample> get loadStream => _loadController.stream;
  Stream<TindeqConnectionState> get stateStream => _stateController.stream;
  Stream<double> get batteryStream => _batteryController.stream;
  Stream<double> get peakLoadStream => _peakLoadController.stream;
  Stream<String> get logStream => _logController.stream;

  TindeqConnectionState _state = TindeqConnectionState.disconnected;
  TindeqConnectionState get state => _state;

  double _peakLoad = 0.0;
  double get peakLoad => _peakLoad;

  void _setState(TindeqConnectionState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  void _log(String message) {
    _logController.add(message);
  }

  /// Scan for and connect to a Tindeq Progressor device.
  Future<void> scanAndConnect() async {
    if (_state != TindeqConnectionState.disconnected) return;

    _setState(TindeqConnectionState.scanning);
    _log('Scanning for Progressor...');

    try {
      // Listen for scan results
      final completer = Completer<BluetoothDevice>();
      final scanSub = FlutterBluePlus.onScanResults.listen((results) {
        for (final result in results) {
          final name = result.device.platformName;
          if (name.toLowerCase().contains('progressor')) {
            if (!completer.isCompleted) {
              completer.complete(result.device);
            }
          }
        }
      });

      await FlutterBluePlus.startScan(
        withServices: [TindeqUuids.service],
        timeout: const Duration(seconds: 15),
      );

      _device = await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('No Progressor found'),
      );

      await FlutterBluePlus.stopScan();
      scanSub.cancel();

      _log('Found ${_device!.platformName}. Connecting...');
      _setState(TindeqConnectionState.connecting);

      await _device!.connect(
        timeout: const Duration(seconds: 10),
        autoConnect: false,
      );

      // Listen for disconnection
      _connectionSub = _device!.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _log('Device disconnected.');
          _cleanup();
          _setState(TindeqConnectionState.disconnected);
        }
      });

      // Allow the connection to stabilize before service discovery
      _log('Connected. Requesting MTU...');
      await _device!.requestMtu(512);
      await Future.delayed(const Duration(milliseconds: 1000));

      _log('Discovering services...');
      final services = await _device!.discoverServices();

      // Find Progressor service
      final svc = services.firstWhere(
        (s) => s.serviceUuid == TindeqUuids.service,
        orElse: () => throw Exception('Progressor service not found'),
      );

      _dataChar = svc.characteristics.firstWhere(
        (c) => c.characteristicUuid == TindeqUuids.data,
      );
      _ctrlChar = svc.characteristics.firstWhere(
        (c) => c.characteristicUuid == TindeqUuids.controlPoint,
      );

      // Enable notifications with retry — Android GATT can be flaky
      _log('Enabling notifications...');
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          await Future.delayed(const Duration(milliseconds: 500));
          await _dataChar!.setNotifyValue(true);
          break;
        } catch (e) {
          _log('Notify attempt $attempt failed: $e');
          if (attempt == 3) rethrow;
          await Future.delayed(Duration(milliseconds: 500 * attempt));
        }
      }
      _notifySub = _dataChar!.onValueReceived.listen(_onDataReceived);

      _setState(TindeqConnectionState.connected);
      _log('Ready. Notifications enabled.');
    } catch (e) {
      _log('Error: $e');
      await disconnect();
    }
  }

  /// Parse incoming BLE notification data from the Progressor.
  void _onDataReceived(List<int> data) {
    if (data.isEmpty) return;

    final responseType = data[0];

    switch (responseType) {
      case TindeqResponse.weightMeasurement:
        _parseWeightData(data);
        break;
      case TindeqResponse.commandResponse:
        _parseCommandResponse(data);
        break;
      case TindeqResponse.lowPowerWarning:
        _log('Low battery warning!');
        break;
      case TindeqResponse.rfdPeak:
        _log('RFD peak received');
        break;
    }
  }

  /// Weight measurement data: pairs of (float32 weight, uint32 timestamp_us)
  /// starting at byte offset 2.
  void _parseWeightData(List<int> data) {
    final bytes = Uint8List.fromList(data);
    final byteData = ByteData.sublistView(bytes);

    // Byte 0: response type, Byte 1: payload length
    // Then repeating 8-byte blocks: 4-byte float (weight) + 4-byte uint (time)
    for (var offset = 2; offset + 8 <= bytes.length; offset += 8) {
      final weight = byteData.getFloat32(offset, Endian.little);
      final microseconds = byteData.getUint32(offset + 4, Endian.little);

      final sample = LoadSample(
        weightKg: weight,
        timestamp: Duration(microseconds: microseconds),
      );

      if (weight > _peakLoad) {
        _peakLoad = weight;
        _peakLoadController.add(_peakLoad);
      }

      _loadController.add(sample);
    }
  }

  void _parseCommandResponse(List<int> data) {
    if (data.length < 3) return;
    final bytes = Uint8List.fromList(data);
    final byteData = ByteData.sublistView(bytes);

    // Try to interpret as battery voltage (uint32 millivolts)
    if (data.length >= 6) {
      final millivolts = byteData.getUint32(2, Endian.little);
      // Battery voltage is typically 3000-4200 mV
      if (millivolts > 2000 && millivolts < 5000) {
        final volts = millivolts / 1000.0;
        _batteryController.add(volts);
        _log('Battery: ${volts.toStringAsFixed(2)}V');
        return;
      }
    }

    // Otherwise treat as UTF-8 string (version info, error info)
    try {
      final text = String.fromCharCodes(data.sublist(2));
      _log('Response: $text');
    } catch (_) {
      _log('Response: ${data.sublist(2)}');
    }
  }

  Future<void> _sendCommand(int opcode) async {
    if (_ctrlChar == null) return;
    await _ctrlChar!.write([opcode], withoutResponse: false);
  }

  Future<void> startMeasurement() async {
    if (_state != TindeqConnectionState.connected &&
        _state != TindeqConnectionState.measuring) {
      return;
    }
    _peakLoad = 0.0;
    _peakLoadController.add(0.0);
    _log('Starting measurement...');
    await _sendCommand(TindeqCommands.startWeightMeasurement);
    _setState(TindeqConnectionState.measuring);
  }

  Future<void> stopMeasurement() async {
    if (_state != TindeqConnectionState.measuring) return;
    _log('Stopping measurement.');
    await _sendCommand(TindeqCommands.stopWeightMeasurement);
    _setState(TindeqConnectionState.connected);
  }

  Future<void> tare() async {
    _log('Taring scale...');
    await _sendCommand(TindeqCommands.tareScale);
  }

  Future<void> requestBattery() async {
    await _sendCommand(TindeqCommands.getBatteryVoltage);
  }

  Future<void> requestAppVersion() async {
    await _sendCommand(TindeqCommands.getAppVersion);
  }

  void resetPeak() {
    _peakLoad = 0.0;
    _peakLoadController.add(0.0);
  }

  Future<void> disconnect() async {
    if (_state == TindeqConnectionState.measuring) {
      try {
        await _sendCommand(TindeqCommands.stopWeightMeasurement);
      } catch (_) {}
    }
    _cleanup();
    try {
      await _device?.disconnect();
    } catch (_) {}
    _setState(TindeqConnectionState.disconnected);
    _log('Disconnected.');
  }

  void _cleanup() {
    _notifySub?.cancel();
    _notifySub = null;
    _connectionSub?.cancel();
    _connectionSub = null;
    _dataChar = null;
    _ctrlChar = null;
    _device = null;
  }

  void dispose() {
    _loadController.close();
    _stateController.close();
    _batteryController.close();
    _peakLoadController.close();
    _logController.close();
    _notifySub?.cancel();
    _connectionSub?.cancel();
  }
}
