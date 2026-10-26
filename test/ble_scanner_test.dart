import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/ble/ble_scanner.dart';

/// Counts discovery starts and stops; stops take a moment, like the radio.
class _SlowCentral implements CentralManager {
  int starts = 0;
  int stops = 0;
  bool on = false;

  @override
  Future<void> startDiscovery({List<UUID>? serviceUUIDs}) async {
    starts++;
    on = true;
  }

  @override
  Future<void> stopDiscovery() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    stops++;
    on = false;
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      i.isGetter ? const Stream<Never>.empty() : Future.value();
}

void main() {
  test('a start that arrives while a stop is running still starts', () async {
    final central = _SlowCentral();
    final scanner = BleScanner(central);
    await scanner.start();
    // A connection pauses the scan; something else restarts it before the
    // stop has finished.
    final stop = scanner.stop();
    final start = scanner.start();
    await Future.wait([stop, start]);
    expect(scanner.scanning, isTrue);
    expect(central.on, isTrue);
    expect(central.starts, 2);
    await scanner.dispose();
  });

  test('a pause for a connection is not the person pausing', () async {
    final central = _SlowCentral();
    final scanner = BleScanner(central);
    await scanner.start();
    expect(scanner.paused, isFalse);
    // A connection stops the scan and resumes it: still not paused.
    await scanner.stop();
    expect(scanner.paused, isFalse);
    await scanner.resume();
    expect(scanner.scanning, isTrue);
    // The person pauses while a connection holds the scan: the connection
    // finishing does not start it again.
    await scanner.stop();
    await scanner.pause();
    await scanner.resume();
    expect(scanner.scanning, isFalse);
    expect(scanner.paused, isTrue);
    await scanner.start();
    expect(scanner.scanning, isTrue);
    expect(scanner.paused, isFalse);
    await scanner.dispose();
  });
}
