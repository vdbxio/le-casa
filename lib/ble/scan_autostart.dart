// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import 'ble_scanner.dart';

/// Starts scanning as soon as Bluetooth allows, whichever screen is up,
/// asking for permission when needed. Moved out of the scan page so the
/// dashboard (the home screen now) gets data without visiting it.
class ScanAutostart extends ChangeNotifier {
  final BleScanner scanner;
  BluetoothLowEnergyState state = BluetoothLowEnergyState.unknown;
  String? error;
  StreamSubscription? _sub;
  bool _asking = false;

  ScanAutostart(this.scanner);

  void start() {
    state = scanner.state;
    _sub = scanner.stateChanges.listen((st) {
      state = st;
      notifyListeners();
      _react(st);
    });
    _react(state);
  }

  /// The plugin starts in `unknown`, then reports the real state once the
  /// platform side is up. React to whatever it says, whenever it says it.
  Future<void> _react(BluetoothLowEnergyState st) async {
    switch (st) {
      case BluetoothLowEnergyState.unauthorized:
        await askPermission();
      case BluetoothLowEnergyState.poweredOn:
        await startScan();
      default:
        break;
    }
  }

  Future<void> askPermission() async {
    if (_asking) return;
    _asking = true;
    try {
      final ok = await scanner.authorize();
      if (!ok) {
        error = 'Bluetooth permission was not granted. Allow "Nearby devices" in Settings.';
        notifyListeners();
        return;
      }
      error = null;
      // The plugin refreshes its state when the app resumes after the
      // permission dialog; give it a moment, then start if it is ready.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      state = scanner.state;
      if (state == BluetoothLowEnergyState.poweredOn) await startScan();
      notifyListeners();
    } finally {
      _asking = false;
    }
  }

  Future<void> startScan() async {
    try {
      await scanner.start();
      error = null;
    } catch (e) {
      error = 'Could not start scanning: $e';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
