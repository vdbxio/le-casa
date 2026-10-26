import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/ble/connection_manager.dart';
import 'package:lecasa/ble/device_tracker.dart';
import 'package:lecasa/ble/gatt_session.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';
import 'package:lecasa/decoders/registry.dart';
import 'package:lecasa/drivers/driver.dart';

import 'fake_session.dart';
import 'helpers.dart';

/// Driver that returns a canned reading, or throws what it is told to.
class ScriptedDriver implements GattDriver {
  Object? error;
  int reads = 0;
  ScriptedDriver({this.error});

  @override
  String get name => 'scripted';
  @override
  Duration get interval => const Duration(seconds: 30);
  @override
  Duration get timeout => const Duration(seconds: 5);
  @override
  bool matches(RawAdvertisement adv) => adv.name == 'TEST';

  @override
  Future<Decoded> read(GattSession s, RawAdvertisement adv) async {
    reads++;
    if (error != null) throw error!;
    return const Decoded(
      protocol: 'test',
      model: 'Test device',
      kind: DeviceKind.battery,
      readings: [Reading('voltage', 12.5, 'V')],
    );
  }
}

class LiveScriptedDriver extends ScriptedDriver implements LiveDriver {
  @override
  Duration get liveInterval => Duration.zero;
}

/// Another screen that wants a device, or not.
class _Aside implements RemoteLinks {
  String? why;
  @override
  RemoteOwner? ownerOf(String id) => null;
  @override
  Future<void> control(String id, DeviceCommand command) async {}
  @override
  String? standAside(String id) => why;
}

class ControlDriver extends ScriptedDriver implements ControllableDriver {
  final commands = <DeviceCommand>[];

  @override
  Future<Decoded> control(
    GattSession s,
    RawAdvertisement adv,
    DeviceCommand command,
  ) async {
    commands.add(command);
    return const Decoded(protocol: 'test', model: 'Controlled');
  }
}

void main() {
  late DeviceTracker tracker;
  late List<FakeSession> opened;

  setUp(() {
    tracker = DeviceTracker(DecoderRegistry.standard());
    opened = [];
  });

  ConnectionManager manager(
    GattDriver driver, {
    SessionOpener? open,
    bool holdLinks = false,
  }) => ConnectionManager(
    tracker,
    holdLinks: holdLinks,
    drivers: GattDriverRegistry([driver]),
    tick: const Duration(hours: 1),
    open:
        open ??
        (id) async {
          final s = FakeSession(characteristics: const []);
          opened.add(s);
          return s;
        },
  );

  final testAdv = adv(
    id: 'AA:BB:CC:DD:EE:01',
    name: 'TEST',
    seenAt: DateTime.now(),
  );

  test('schedules a recognised device, reads it, stores the result', () async {
    final driver = ScriptedDriver();
    final m = manager(driver);
    tracker.onAdvertisement(testAdv);
    m.onAdvertisement(testAdv);
    expect(m[testAdv.id]?.phase, LinkPhase.scheduled);

    await m.pump();

    expect(driver.reads, 1);
    expect(m[testAdv.id]?.phase, LinkPhase.ok);
    expect(tracker[testAdv.id]!.view?.model, 'Test device');
    expect(tracker[testAdv.id]!.polledAt, isNotNull);
    expect(opened.single.closed, isTrue, reason: 'disconnects after reading');
    expect(m.busyId, isNull);
    // A later broadcast does not wipe the connected reading.
    tracker.onAdvertisement(testAdv);
    expect(tracker[testAdv.id]!.view?.model, 'Test device');
    m.dispose();
  });

  test('nothing polls while another connect has the radio', () async {
    final driver = ScriptedDriver();
    final m = manager(driver);
    tracker.onAdvertisement(testAdv);
    m.onAdvertisement(testAdv);
    final gate = Completer<void>();
    final held = m.exclusive('sync hub', () => gate.future);
    await m.pump();
    expect(driver.reads, 0);
    expect(m.busyId, 'sync hub');
    gate.complete();
    await held;
    await m.pump();
    expect(driver.reads, 1);
    m.dispose();
  });

  test('a Bluetooth call that never returns lets go of the radio', () async {
    final driver = ScriptedDriver();
    final m = manager(driver);
    tracker.onAdvertisement(testAdv);
    m.onAdvertisement(testAdv);
    final stuck = m.exclusive(
      'screen sync',
      () => Completer<void>().future,
      limit: const Duration(milliseconds: 50),
    );
    await expectLater(stuck, throwsA(isA<TimeoutException>()));
    expect(m.busyId, isNull);
    await m.pump();
    expect(driver.reads, 1);
    m.dispose();
  });

  test('a connect that never returns gives the radio back', () async {
    final driver = ScriptedDriver();
    var hang = true;
    final m = manager(
      driver,
      open: (id) async {
        if (hang) await Completer<void>().future;
        return FakeSession(characteristics: const []);
      },
    )..stuckAfter = const Duration(milliseconds: 50);
    tracker.onAdvertisement(testAdv);
    m.onAdvertisement(testAdv);
    unawaited(m.pump());
    await Future<void>.delayed(Duration.zero);
    expect(m.busyId, testAdv.id);
    await m.pump();
    expect(driver.reads, 0, reason: 'still within the limit');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    hang = false;
    await m.readNow(testAdv.id);
    expect(m[testAdv.id]?.error, isNull);
    expect(driver.reads, 1);
    expect(m.busyId, isNull);
    m.dispose();
  });

  test('does not poll again before the interval', () async {
    final driver = ScriptedDriver();
    final m = manager(driver);
    tracker.onAdvertisement(testAdv);
    m.onAdvertisement(testAdv);
    await m.pump();
    await m.pump();
    expect(driver.reads, 1);
    await m.readNow(testAdv.id);
    expect(driver.reads, 2);
    m.dispose();
  });

  test('failure backs off and still closes the link', () async {
    final driver = ScriptedDriver(error: TimeoutException('no answer'));
    final m = manager(driver);
    tracker.onAdvertisement(testAdv);
    m.onAdvertisement(testAdv);
    await m.pump();
    final l = m[testAdv.id]!;
    expect(l.phase, LinkPhase.failed);
    expect(l.error, 'no answer');
    expect(l.failures, 1);
    expect(l.nextDue.isAfter(DateTime.now()), isTrue);
    expect(opened.single.closed, isTrue);
    m.dispose();
  });

  test('a device that keeps dropping the link is flagged', () async {
    // The pending write fails first and the disconnect event follows, the
    // order Android reports them in.
    final driver = ScriptedDriver(
      error: Exception('Write descriptor failed with status: 133.'),
    );
    var drop = true;
    var failConnect = false;
    final m = manager(
      driver,
      open: (id) async {
        if (failConnect) throw Exception('Connect failed with status: 133');
        final s = FakeSession(characteristics: const []);
        if (drop) Timer(const Duration(milliseconds: 50), s.drop);
        opened.add(s);
        return s;
      },
    );
    tracker.onAdvertisement(testAdv);
    m.onAdvertisement(testAdv);
    for (var i = 0; i < Link.dropsToWarn; i++) {
      expect(m[testAdv.id]!.keepsDropping, isFalse);
      await m.readNow(testAdv.id);
      // a failed connect in between, as on the M10
      failConnect = true;
      await m.readNow(testAdv.id);
      failConnect = false;
    }
    final l = m[testAdv.id]!;
    expect(l.keepsDropping, isTrue);
    // Connect failures in between do not clear it; a good read does.
    drop = false;
    driver.error = null;
    await m.readNow(testAdv.id);
    expect(l.keepsDropping, isFalse);
    m.dispose();
  });

  test('a status 8 error counts as a drop straight away', () async {
    final driver = ScriptedDriver(
      error: Exception('GATT is disconnected with status: 8'),
    );
    final m = manager(driver);
    tracker.onAdvertisement(testAdv);
    m.onAdvertisement(testAdv);
    await m.pump();
    expect(m[testAdv.id]!.drops, 1);
    expect(m[testAdv.id]!.error, 'The device dropped the connection');
    m.dispose();
  });

  test('a status 8 while connecting counts as a drop too', () async {
    final m = manager(
      ScriptedDriver(),
      open: (id) async =>
          throw Exception('GATT is disconnected with status: 8'),
    );
    tracker.onAdvertisement(testAdv);
    m.onAdvertisement(testAdv);
    await m.pump();
    expect(m[testAdv.id]!.drops, 1);
    expect(m[testAdv.id]!.error, 'The device dropped the connection');
    m.dispose();
  });

  test('control connects, sends the command and stores the result', () async {
    final driver = ControlDriver();
    final m = manager(driver);
    tracker.onAdvertisement(testAdv);
    m.onAdvertisement(testAdv);
    expect(m.canControl(testAdv.id), isTrue);
    await m.control(testAdv.id, const DeviceCommand('power', false));
    expect(driver.commands.single.setting, 'power');
    expect(tracker[testAdv.id]!.view?.model, 'Controlled');
    expect(opened.single.closed, isTrue);
    expect(m.busyId, isNull);
    await m.setDeviceEnabled(testAdv.id, false);
    expect(
      () => m.control(testAdv.id, const DeviceCommand('power', true)),
      throwsStateError,
    );
    m.dispose();
  });

  test('read-only drivers cannot be controlled', () async {
    final m = manager(ScriptedDriver());
    tracker.onAdvertisement(testAdv);
    m.onAdvertisement(testAdv);
    expect(m.canControl(testAdv.id), isFalse);
    expect(
      () => m.control(testAdv.id, const DeviceCommand('power', true)),
      throwsStateError,
    );
    m.dispose();
  });

  test('unsupported devices are parked, not retried', () async {
    final driver = ScriptedDriver(
      error: const UnsupportedDeviceException('no such characteristic'),
    );
    final m = manager(driver);
    tracker.onAdvertisement(testAdv);
    m.onAdvertisement(testAdv);
    await m.pump();
    expect(m[testAdv.id]!.phase, LinkPhase.unsupported);
    expect(m[testAdv.id]!.enabled, isFalse);
    await m.readNow(testAdv.id);
    expect(driver.reads, 1);
    m.dispose();
  });

  test('a connect error is reported and the device retried later', () async {
    final driver = ScriptedDriver();
    final m = manager(
      driver,
      open: (id) async => throw StateError('Device not seen by the scanner'),
    );
    tracker.onAdvertisement(testAdv);
    m.onAdvertisement(testAdv);
    await m.pump();
    expect(m[testAdv.id]!.phase, LinkPhase.failed);
    expect(m[testAdv.id]!.error, contains('not seen'));
    expect(driver.reads, 0);
    m.dispose();
  });

  test('per-device and global switches stop polling', () async {
    final driver = ScriptedDriver();
    final m = manager(driver);
    tracker.onAdvertisement(testAdv);
    m.onAdvertisement(testAdv);
    await m.setDeviceEnabled(testAdv.id, false);
    await m.pump();
    expect(driver.reads, 0);
    expect(m[testAdv.id]!.phase, LinkPhase.off);
    await m.setDeviceEnabled(testAdv.id, true);
    await m.setEnabled(false);
    await m.pump();
    expect(driver.reads, 0);
    await m.setEnabled(true);
    await m.pump();
    expect(driver.reads, 1);
    m.dispose();
  });

  test('devices not heard for a while are not connected to', () async {
    final driver = ScriptedDriver();
    final m = manager(driver);
    final old = adv(id: 'AA:BB:CC:DD:EE:03', name: 'TEST');
    tracker.onAdvertisement(old);
    m.onAdvertisement(old);
    await m.pump();
    expect(driver.reads, 0);
    expect(m[old.id]!.phase, LinkPhase.scheduled);
    m.dispose();
  });

  test('unrecognised devices are ignored', () {
    final m = manager(ScriptedDriver());
    final other = adv(
      id: 'AA:BB:CC:DD:EE:02',
      name: 'OTHER',
      seenAt: DateTime.now(),
    );
    tracker.onAdvertisement(other);
    m.onAdvertisement(other);
    expect(m.links, isEmpty);
    m.dispose();
  });

  group('live links', () {
    test('a live device stays connected and is read again', () async {
      final driver = LiveScriptedDriver();
      final m = manager(driver, holdLinks: true);
      tracker.onAdvertisement(testAdv);
      m.onAdvertisement(testAdv);
      await m.pump();
      expect(m.isLive(testAdv.id), isTrue);
      expect(opened.single.closed, isFalse);
      expect(m.busyId, isNull, reason: 'other devices can still be read');
      await m.pump();
      await m.pump();
      expect(driver.reads, 3);
      expect(opened, hasLength(1));
      m.dispose();
    });

    test('only on screens that hold links', () async {
      final driver = LiveScriptedDriver();
      final m = manager(driver);
      tracker.onAdvertisement(testAdv);
      m.onAdvertisement(testAdv);
      await m.pump();
      expect(m.isLive(testAdv.id), isFalse);
      expect(opened.single.closed, isTrue);
      m.dispose();
    });

    test('reconnects when the device drops the link', () async {
      final driver = LiveScriptedDriver();
      final m = manager(driver, holdLinks: true);
      tracker.onAdvertisement(testAdv);
      m.onAdvertisement(testAdv);
      await m.pump();
      opened.single.drop();
      await Future<void>.delayed(Duration.zero);
      expect(m.isLive(testAdv.id), isFalse);
      await m.pump();
      expect(opened, hasLength(2));
      expect(m.isLive(testAdv.id), isTrue);
      m.dispose();
    });

    test('lets go when another screen should read it', () async {
      final driver = LiveScriptedDriver();
      final aside = _Aside();
      final m = manager(driver, holdLinks: true)..remote = aside;
      tracker.onAdvertisement(testAdv);
      m.onAdvertisement(testAdv);
      await m.pump();
      aside.why = 'Locked to the iPad';
      await m.pump();
      expect(m.isLive(testAdv.id), isFalse);
      expect(opened.single.closed, isTrue);
      expect(driver.reads, 1);
      m.dispose();
    });

    test('lets go when turned off', () async {
      final driver = LiveScriptedDriver();
      final m = manager(driver, holdLinks: true);
      tracker.onAdvertisement(testAdv);
      m.onAdvertisement(testAdv);
      await m.pump();
      await m.setDeviceEnabled(testAdv.id, false);
      expect(m.isLive(testAdv.id), isFalse);
      expect(opened.single.closed, isTrue);
      m.dispose();
    });
  });
}
