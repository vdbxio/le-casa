import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/ble/connection_manager.dart';
import 'package:lecasa/ble/device_tracker.dart';
import 'package:lecasa/ble/gatt_session.dart';
import 'package:lecasa/decoders/decoded.dart';
import 'package:lecasa/decoders/raw_advertisement.dart';
import 'package:lecasa/decoders/registry.dart';
import 'package:lecasa/drivers/driver.dart';
import 'package:lecasa/keys/key_store.dart';
import 'package:lecasa/sync/framing.dart';
import 'package:lecasa/sync/home.dart';
import 'package:lecasa/sync/radio.dart';
import 'package:lecasa/sync/read_by.dart';
import 'package:lecasa/sync/sync_service.dart';
import 'package:lecasa/sync/wire.dart';

import '../fake_session.dart';
import 'pipe.dart';

/// The air between fake radios: screens advertise here, others connect.
class Air {
  final servers = <String, FakeRadio>{};
  final listeners = <FakeRadio>[];

  /// Signal [listener] hears [server] at, or null when out of range.
  int? Function(FakeRadio listener, FakeRadio server) signal = (_, _) => -50;
}

class FakeRadio implements SyncRadio {
  final Air air;
  final String id;
  final _incoming = StreamController<MessageLink>.broadcast();
  final _sightings = StreamController<PeerSighting>.broadcast();
  PeerAdvert? ad;

  /// How many more startServer calls fail, like iOS before Bluetooth is up.
  int failStarts = 0;

  FakeRadio(this.air, this.id) {
    air.listeners.add(this);
  }

  /// Every listener in range hears every server, as a scan would.
  static Future<void> advertise(Air air) async {
    for (final h in air.servers.values) {
      for (final l in air.listeners) {
        final rssi = l == h ? null : air.signal(l, h);
        if (rssi == null) continue;
        l._sightings.add(
          PeerSighting(
            h.id,
            h.ad!.tag,
            rssi,
            DateTime.now(),
            screen: h.ad!.screen,
            adding: h.ad!.adding,
          ),
        );
      }
    }
    await pumpEventQueue();
  }

  @override
  Future<void> startServer(PeerAdvert ad) async {
    if (failStarts > 0) {
      failStarts--;
      throw StateError('Bluetooth is unknown');
    }
    this.ad = ad;
    air.servers[id] = this;
  }

  @override
  Future<void> stopServer() async => air.servers.remove(id);

  @override
  Stream<MessageLink> get incoming => _incoming.stream;

  @override
  Stream<PeerSighting> get sightings => _sightings.stream;

  @override
  Future<MessageLink> connect(PeerSighting peer) async {
    final h = air.servers[peer.id];
    if (h == null) throw StateError('not there');
    final (a, b) = PipeEnd.pair(maxChunk: 64);
    h._incoming.add(MessageLink(b));
    return MessageLink(a);
  }
}

/// Fridge-ish driver: reads a target, and changes it on command.
class FridgeDriver implements ControllableDriver {
  int target = 48;
  final commands = <DeviceCommand>[];

  @override
  String get name => 'fridge';
  @override
  Duration get interval => const Duration(seconds: 30);
  @override
  Duration get timeout => const Duration(seconds: 5);
  @override
  bool matches(RawAdvertisement adv) => adv.name?.startsWith('AK1-') ?? false;

  Decoded get _state => Decoded(
    protocol: 'Alpicool',
    model: 'Fridge',
    kind: DeviceKind.appliance,
    readings: [Reading('target', target, '°F')],
  );

  @override
  Future<Decoded> read(GattSession s, RawAdvertisement adv) async => _state;

  @override
  Future<Decoded> control(
    GattSession s,
    RawAdvertisement adv,
    DeviceCommand c,
  ) async {
    commands.add(c);
    target = c.value as int;
    return _state;
  }
}

class Screen {
  final HomeStore home;
  final DeviceTracker tracker = DeviceTracker(DecoderRegistry([]));
  final KeyStore keys = KeyStore();
  final FridgeDriver driver = FridgeDriver();
  late final ConnectionManager connections;
  late final SyncService sync;
  final FakeRadio radio;

  Screen(
    Air air,
    String id,
    String name, {
    bool phone = false,
    Duration? visitEvery,
  }) : home = HomeStore.memory(id, name, phone: phone),
       radio = FakeRadio(air, id) {
    connections = ConnectionManager(
      tracker,
      open: (_) async => FakeSession(characteristics: const []),
      drivers: GattDriverRegistry([driver]),
      tick: const Duration(days: 1),
    );
    sync =
        SyncService(
            home: home,
            tracker: tracker,
            keys: keys,
            connections: connections,
            radio: radio,
            readBy: ReadByStore.memory(),
            visitEvery: visitEvery,
          )
          ..settleTime = Duration.zero
          ..shareEvery = Duration.zero
          ..start();
    keys.label = (id) => (
      name: tracker[id]?.latest.name,
      mac: tracker[id]?.latest.macString,
      fp: tracker[id] == null ? null : advertFingerprint(tracker[id]!.latest),
    );
  }

  void hear(
    String id,
    String? name, {
    int rssi = -60,
    Map<int, Uint8List> mfr = const {},
  }) {
    final adv = RawAdvertisement(
      id: id,
      rssi: rssi,
      seenAt: DateTime.now(),
      name: name,
      mac: parseMac(id),
      manufacturerData: mfr,
    );
    tracker.onAdvertisement(adv);
    connections.onAdvertisement(adv);
  }

  void dispose() {
    sync.dispose();
    connections.dispose();
  }
}

/// Lets messages cross the in-memory links.
Future<void> settle([int rounds = 5]) async {
  for (var i = 0; i < rounds; i++) {
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Pairs [newcomer] through [via], which must already be in a home.
Future<void> pairThrough(Air air, Screen via, Screen newcomer) async {
  via.sync.startAdding();
  await settle();
  await FakeRadio.advertise(air);
  final peer = newcomer.sync.nearby.values.singleWhere(
    (h) => h.id == via.radio.id && h.adding,
  );
  final join = newcomer.sync.join(peer);
  await settle();
  expect(via.sync.prompt, isNotNull);
  expect(newcomer.sync.prompt?.code, via.sync.prompt!.code);
  via.sync.answer(true);
  newcomer.sync.answer(true);
  await join;
  expect(newcomer.home.key, via.home.key);
  await settle();
}

/// Lets every screen hear the others and dial the ones it should.
Future<void> link(Air air, List<Screen> screens) async {
  for (final s in screens) {
    s.sync.dialWait = Duration.zero;
  }
  await FakeRadio.advertise(air);
  for (final s in screens) {
    await s.sync.tick();
    await settle();
  }
}

void main() {
  late Air air;
  late Screen ipad, m10;

  // The iPad knows the fridge by a random id (iOS hides MACs); the M10 by
  // its MAC. Same advertised name.
  const ipadFridge = '6F1C0E42-0000-4000-8000-000000000001';
  const m10Fridge = 'AA:FE:13:15:64:31';

  setUp(() async {
    air = Air();
    ipad = Screen(air, 'ipad', 'Kitchen iPad');
    m10 = Screen(air, 'm10', 'M10');
    await ipad.sync.startHome('Van');
    await pairThrough(air, ipad, m10);
    expect(m10.home.inHome, isTrue);
    await link(air, [ipad, m10]);
    expect(m10.sync.connected, isTrue);
    expect(ipad.sync.linked.single.name, 'M10');
    expect(m10.sync.linked.single.name, 'Kitchen iPad');
  });

  tearDown(() {
    ipad.dispose();
    m10.dispose();
  });

  test('each screen knows the others', () {
    expect(m10.sync.screens.map((s) => s.name), ['M10', 'Kitchen iPad']);
    expect(ipad.sync.screens.map((s) => s.name), ['Kitchen iPad', 'M10']);
  });

  test(
    'a reading one screen takes shows on the other, which backs off',
    () async {
      ipad.hear(ipadFridge, 'AK1-AAFE13156431');
      m10.hear(m10Fridge, 'AK1-AAFE13156431');
      await ipad.connections.readNow(ipadFridge);
      await ipad.sync.tick();
      await settle();
      final d = m10.tracker[m10Fridge]!;
      expect(d.polledBy, 'Kitchen iPad');
      expect(d.polled!.readings.single.value, 48);
      expect(m10.connections.heldElsewhere(m10Fridge)?.screen, 'Kitchen iPad');
      expect(m10.connections.canControl(m10Fridge), isTrue);
      // The M10 does not connect to the fridge while the iPad has it.
      await m10.connections.pump();
      expect(m10.connections[m10Fridge]!.lastAttempt, isNull);
    },
  );

  test('a device locked to one screen is left alone by the others', () async {
    ipad.hear(ipadFridge, 'AK1-AAFE13156431');
    m10.hear(m10Fridge, 'AK1-AAFE13156431');
    await ipad.sync.lock(ipadFridge, m10.home.me);
    await settle();
    expect(m10.sync.readBy.lockOf(m10Fridge)?.screen, 'm10');
    expect(ipad.sync.standAside(ipadFridge), 'Locked to M10');
    await ipad.connections.pump();
    expect(ipad.connections[ipadFridge]!.lastAttempt, isNull);
    expect(m10.sync.standAside(m10Fridge), isNull);
    await m10.connections.pump();
    expect(m10.connections[m10Fridge]!.lastOk, isNotNull);
    // A control on the iPad goes to the M10 even before it shares a reading.
    await ipad.connections.control(
      ipadFridge,
      const DeviceCommand('target', 41),
    );
    expect(m10.driver.commands.single.value, 41);
    // Back to automatic.
    await m10.sync.lock(m10Fridge, null);
    await settle();
    expect(ipad.sync.readBy.lockOf(ipadFridge), isNull);
  });

  test('the screen that hears a device better goes first', () async {
    ipad.sync.handoverGrace = const Duration(hours: 1);
    ipad.hear(ipadFridge, 'AK1-AAFE13156431', rssi: -85);
    m10.hear(m10Fridge, 'AK1-AAFE13156431', rssi: -40);
    await m10.sync.beacon();
    await ipad.sync.beacon();
    await settle();
    expect(ipad.sync.standAside(ipadFridge), 'M10 hears it better');
    expect(m10.sync.standAside(m10Fridge), isNull);
    // If the M10 never reads it, the iPad takes it after the grace period.
    ipad.sync.handoverGrace = Duration.zero;
    expect(ipad.sync.standAside(ipadFridge), isNull);
  });

  test('a phone leaves devices to the tablets that hear them', () async {
    final phone = Screen(air, 'phone', 'iPhone', phone: true);
    addTearDown(phone.dispose);
    await pairThrough(air, ipad, phone);
    await link(air, [ipad, m10, phone]);
    const phoneFridge = '0C0C0C0C-0000-4000-8000-000000000009';
    phone.hear(phoneFridge, 'AK1-AAFE13156431', rssi: -30);
    m10.hear(m10Fridge, 'AK1-AAFE13156431', rssi: -70);
    await m10.sync.beacon();
    await settle();
    expect(phone.sync.standAside(phoneFridge), contains('M10 reads it'));
    // Unless it is locked to the phone.
    await phone.sync.lock(phoneFridge, phone.home.me);
    expect(phone.sync.standAside(phoneFridge), isNull);
  });

  test('a device with no MAC and another name matches by its data', () async {
    // The Daly: a random id and "DL-…" on iOS, its MAC and no name on
    // Android. Only the manufacturer data is the same.
    final mfr = {
      0x302: Uint8List.fromList([0x16, 0x40, 0x17, 0x10, 0x01, 0x5c]),
    };
    const ipadDaly = '7E48D8DF-E13A-24F8-78D4-C05C53494BA3';
    const m10Daly = 'D2:19:08:01:C5:61';
    ipad.hear(ipadDaly, 'DL-694201312BA', mfr: mfr);
    m10.hear(m10Daly, null, mfr: mfr);
    ipad.tracker.setPolled(
      ipadDaly,
      const Decoded(
        protocol: 'Daly',
        model: 'BMS',
        kind: DeviceKind.battery,
        readings: [Reading('voltage', 26.5, 'V')],
      ),
    );
    await ipad.sync.tick();
    await settle();
    expect(m10.tracker[m10Daly]!.polledBy, 'Kitchen iPad');
    expect(m10.tracker[ipadDaly], isNull);
  });

  test('a reading that came before the device was heard moves over', () async {
    final mfr = {
      0x302: Uint8List.fromList([0x16, 0x40, 0x17, 0x10, 0x01, 0x5c]),
    };
    const ipadDaly = '7E48D8DF-E13A-24F8-78D4-C05C53494BA3';
    const m10Daly = 'D2:19:08:01:C5:61';
    ipad.hear(ipadDaly, 'DL-694201312BA', mfr: mfr);
    ipad.tracker.setPolled(
      ipadDaly,
      const Decoded(
        protocol: 'Daly',
        model: 'BMS',
        kind: DeviceKind.battery,
        readings: [Reading('voltage', 26.5, 'V')],
      ),
    );
    await ipad.sync.tick();
    await settle();
    expect(m10.tracker[ipadDaly]!.remoteOnly, isTrue);
    m10.hear(m10Daly, null, mfr: mfr);
    for (var i = 0; i < 5; i++) {
      await m10.sync.tick();
    }
    expect(m10.tracker[ipadDaly], isNull);
    expect(m10.tracker[m10Daly]!.polledBy, 'Kitchen iPad');
    expect(m10.connections.heldElsewhere(m10Daly)?.screen, 'Kitchen iPad');
  });

  test('a phone that got to a device first gives it to a tablet', () async {
    final phone = Screen(air, 'phone', 'iPhone', phone: true);
    addTearDown(phone.dispose);
    await pairThrough(air, ipad, phone);
    await link(air, [ipad, m10, phone]);
    const phoneFridge = '0C0C0C0C-0000-4000-8000-000000000009';
    phone.hear(phoneFridge, 'AK1-AAFE13156431');
    m10.hear(m10Fridge, 'AK1-AAFE13156431');
    await phone.connections.readNow(phoneFridge);
    await phone.sync.tick();
    await settle();
    expect(m10.tracker[m10Fridge]!.polledBy, 'iPhone');
    expect(m10.connections.heldElsewhere(m10Fridge), isNull);
    await m10.connections.pump();
    await m10.sync.tick();
    await settle();
    expect(phone.connections.heldElsewhere(phoneFridge)?.screen, 'M10');
  });

  test('a device the other screen never heard still shows up', () async {
    ipad.hear(ipadFridge, 'AK1-AAFE13156431');
    await ipad.connections.readNow(ipadFridge);
    await ipad.sync.tick();
    await settle();
    final d = m10.tracker[ipadFridge]!;
    expect(d.remoteOnly, isTrue);
    expect(d.title, 'Fridge');
  });

  test('a control on one screen runs on the one that reads it', () async {
    ipad.hear(ipadFridge, 'AK1-AAFE13156431');
    m10.hear(m10Fridge, 'AK1-AAFE13156431');
    await ipad.connections.readNow(ipadFridge);
    await ipad.sync.tick();
    await settle();
    final done = m10.connections.control(
      m10Fridge,
      const DeviceCommand('target', 46),
    );
    await settle();
    await done;
    expect(ipad.driver.commands.single.value, 46);
    expect(m10.driver.commands, isEmpty);
    await ipad.sync.tick();
    await settle();
    expect(m10.tracker[m10Fridge]!.polled!.readings.single.value, 46);
  });
  test('a failed control comes back as an error', () async {
    ipad.hear(ipadFridge, 'AK1-AAFE13156431');
    m10.hear(m10Fridge, 'AK1-AAFE13156431');
    await ipad.connections.readNow(ipadFridge);
    await ipad.sync.tick();
    await settle();
    await ipad.connections.setDeviceEnabled(ipadFridge, false);
    final done = m10.connections.control(
      m10Fridge,
      const DeviceCommand('target', 40),
    );
    final check = expectLater(
      done,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Connect to this device'),
        ),
      ),
    );
    await settle();
    await check;
  });

  test('turning a device on or off on one screen does it on all', () async {
    ipad.hear(ipadFridge, 'AK1-AAFE13156431');
    m10.hear(m10Fridge, 'AK1-AAFE13156431');
    await ipad.connections.setDeviceEnabled(ipadFridge, false);
    await settle();
    expect(m10.connections.allows(m10Fridge), isFalse);
    expect(m10.connections[m10Fridge]!.enabled, isFalse);
    await m10.connections.setDeviceEnabled(m10Fridge, true);
    await settle();
    expect(ipad.connections.allows(ipadFridge), isTrue);
  });

  test(
    'a key typed on one screen lands on the other under its own id',
    () async {
      const ipadShunt = '0B2D1E77-0000-4000-8000-000000000002';
      const m10Shunt = 'D1:22:33:44:55:66';
      ipad.hear(ipadShunt, 'Lilith');
      m10.hear(m10Shunt, 'Lilith');
      await m10.keys.set(m10Shunt, '00112233445566778899aabbccddeeff');
      await settle();
      expect(ipad.keys.keyFor(ipadShunt)?.first, 0x00);
      expect(ipad.keys.keyFor(ipadShunt)?.last, 0xff);
      // Removing it travels too.
      await ipad.keys.remove(ipadShunt);
      await settle();
      expect(m10.keys.has(m10Shunt), isFalse);
    },
  );

  test(
    'a key for a device the other screen has not heard yet waits for it',
    () async {
      const ipadShunt = '0B2D1E77-0000-4000-8000-000000000002';
      ipad.hear(ipadShunt, 'Lilith');
      await ipad.keys.set(ipadShunt, '00112233445566778899aabbccddeeff');
      await settle();
      const m10Shunt = 'D1:22:33:44:55:66';
      expect(m10.keys.has(m10Shunt), isFalse);
      m10.hear(m10Shunt, 'Lilith');
      for (var i = 0; i < 5; i++) {
        await m10.sync.tick();
      }
      expect(m10.keys.has(m10Shunt), isTrue);
    },
  );

  test(
    'a key for one of two identical sensors never lands on the other',
    () async {
      // The M10 knows both by MAC; the iPad has heard only the other one,
      // and not yet learnt its MAC.
      const m10Warm = 'A4:C1:38:DF:07:81';
      const m10Cold = 'A4:C1:38:50:6E:3A';
      const ipadCold = '8918B170-0000-4000-8000-6D06C31036F5';
      m10.hear(m10Warm, 'LYWSD03MMC');
      m10.hear(m10Cold, 'LYWSD03MMC');
      ipad.hear(ipadCold, 'LYWSD03MMC');
      await m10.keys.set(m10Warm, '00112233445566778899aabbccddeeff');
      await settle();
      for (var i = 0; i < 5; i++) {
        await ipad.sync.tick();
      }
      expect(ipad.keys.has(ipadCold), isFalse);
    },
  );

  test('a key filed under the wrong sensor is dropped there only', () async {
    const m10Warm = 'A4:C1:38:DF:07:81';
    const m10Cold = 'A4:C1:38:50:6E:3A';
    m10.hear(m10Cold, 'LYWSD03MMC');
    await m10.keys.apply(
      const KeyRecord(
        SecretKind.key,
        m10Cold,
        name: 'LYWSD03MMC',
        mac: m10Warm,
        value: '00112233445566778899aabbccddeeff',
        at: 1,
      ),
    );
    expect(m10.keys.has(m10Cold), isTrue);
    for (var i = 0; i < 5; i++) {
      await m10.sync.tick();
    }
    await settle();
    expect(m10.keys.has(m10Cold), isFalse);
    // No removal went out for the other screens to copy.
    expect(m10.keys.records.where((r) => r.id == m10Cold), isEmpty);
  });

  test(
    'a third screen joins through any screen and extends the mesh',
    () async {
      // The phone is only in range of the M10, and pairs through it.
      final phone = Screen(air, 'phone', 'iPhone', phone: true);
      addTearDown(phone.dispose);
      air.signal = (l, h) =>
          {l.id, h.id}.containsAll(['phone', 'ipad']) ? null : -50;
      await pairThrough(air, m10, phone);
      await link(air, [ipad, m10, phone]);
      expect(phone.sync.linked.map((s) => s.name), ['M10']);
      expect(ipad.sync.linked.map((s) => s.name), ['M10']);
      // The iPad and the phone still know of each other, through the M10.
      expect(phone.sync.screens.map((s) => s.name), contains('Kitchen iPad'));
      expect(ipad.sync.screens.map((s) => s.name), contains('iPhone'));
      // A reading the iPad takes travels iPad -> M10 -> phone.
      ipad.hear(ipadFridge, 'AK1-AAFE13156431');
      await ipad.connections.readNow(ipadFridge);
      await ipad.sync.tick();
      await settle();
      expect(phone.tracker[ipadFridge]?.polledBy, 'Kitchen iPad');
      // And a control from the phone travels phone -> M10 -> iPad.
      final done = phone.connections.control(
        ipadFridge,
        const DeviceCommand('target', 44),
      );
      await settle(10);
      await done;
      expect(ipad.driver.commands.single.value, 44);
    },
  );

  group('renaming', () {
    test('a name given on one screen shows on the other', () async {
      ipad.hear(ipadFridge, 'AK1-AAFE13156431');
      m10.hear(m10Fridge, 'AK1-AAFE13156431');
      await ipad.sync.rename(ipadFridge, 'Galley fridge');
      await settle();
      expect(m10.tracker[m10Fridge]!.label, 'Galley fridge');
      expect(ipad.tracker[ipadFridge]!.label, 'Galley fridge');
      // Clearing it travels too.
      await m10.sync.rename(m10Fridge, '  ');
      await settle();
      expect(ipad.tracker[ipadFridge]!.label, isNull);
    });

    test(
      'a name and a lock chosen at once on two screens both stick',
      () async {
        // Each screen made its choice before hearing the other's.
        final renamed = ReadByStore.memory();
        final locked = ReadByStore.memory();
        const name = ReadByRecord(
          'x',
          label: 'Galley fridge',
          labelAt: 100,
          at: 100,
        );
        const lock = ReadByRecord('x', screen: 'm10', choiceAt: 200, at: 200);
        await renamed.apply(name);
        await locked.apply(lock);
        expect(await renamed.apply(lock), isTrue);
        expect(await locked.apply(name), isTrue);
        for (final s in [renamed, locked]) {
          expect(s.labelOf('x'), 'Galley fridge');
          expect(s.lockOf('x')?.screen, 'm10');
          expect(s.records.single.at, 200);
        }
        // Hearing either again changes nothing, so nothing goes round.
        expect(await renamed.apply(name), isFalse);
        expect(await locked.apply(lock), isFalse);
      },
    );

    test(
      'a name for a device the other screen hears later waits for it',
      () async {
        const ipadShunt = '0B2D1E77-0000-4000-8000-000000000002';
        ipad.hear(ipadShunt, 'Lilith');
        await ipad.sync.rename(ipadShunt, 'House battery');
        await settle();
        const m10Shunt = 'D1:22:33:44:55:66';
        m10.hear(m10Shunt, 'Lilith');
        for (var i = 0; i < 5; i++) {
          await m10.sync.tick();
        }
        expect(m10.tracker[m10Shunt]!.label, 'House battery');
      },
    );

    test('the Daly is renamed across iOS and Android by its data', () async {
      // A random id and "DL-…" on iOS, its MAC and no name on Android.
      final mfr = {
        0x302: Uint8List.fromList([0x16, 0x40, 0x17, 0x10, 0x01, 0x5c]),
      };
      const ipadDaly = '7E48D8DF-E13A-24F8-78D4-C05C53494BA3';
      const m10Daly = 'D2:19:08:01:C5:61';
      ipad.hear(ipadDaly, 'DL-694201312BA', mfr: mfr);
      m10.hear(m10Daly, null, mfr: mfr);
      await m10.sync.rename(m10Daly, 'House bank');
      await settle();
      expect(ipad.tracker[ipadDaly]!.label, 'House bank');
    });

    test('iOS learns a MAC from Android and names the device by it', () async {
      final mfr = {
        0x302: Uint8List.fromList([0x16, 0x40, 0x17, 0x10, 0x01, 0x5c]),
      };
      const ipadDaly = '7E48D8DF-E13A-24F8-78D4-C05C53494BA3';
      const m10Daly = 'D2:19:08:01:C5:61';
      ipad.hear(ipadDaly, 'DL-694201312BA', mfr: mfr);
      m10.hear(m10Daly, null, mfr: mfr);
      m10.tracker.setPolled(
        m10Daly,
        const Decoded(
          protocol: 'Daly',
          model: 'BMS',
          kind: DeviceKind.battery,
          readings: [Reading('voltage', 26.5, 'V')],
        ),
      );
      await m10.sync.tick();
      await settle();
      expect(ipad.tracker[ipadDaly]!.mac, m10Daly);
    });

    test('a Daly PIN typed on iOS reaches Android by its data', () async {
      final mfr = {
        0x302: Uint8List.fromList([0x16, 0x40, 0x17, 0x10, 0x01, 0x5c]),
      };
      const ipadDaly = '7E48D8DF-E13A-24F8-78D4-C05C53494BA3';
      const m10Daly = 'D2:19:08:01:C5:61';
      ipad.hear(ipadDaly, 'DL-694201312BA', mfr: mfr);
      m10.hear(m10Daly, null, mfr: mfr);
      await ipad.keys.setSecret(ipadDaly, '12345678');
      await settle();
      expect(m10.keys.secretFor(m10Daly), '12345678');
    });

    test(
      'a device known only through the other screen takes its name',
      () async {
        ipad.hear(ipadFridge, 'AK1-AAFE13156431');
        await ipad.connections.readNow(ipadFridge);
        await ipad.sync.tick();
        await settle();
        final remote = m10.tracker[ipadFridge]!;
        expect(remote.remoteOnly, isTrue);
        await m10.sync.rename(ipadFridge, 'Galley fridge');
        await settle();
        expect(ipad.tracker[ipadFridge]!.label, 'Galley fridge');
        // Once the M10 hears the fridge itself, under its MAC, the name
        // follows it there.
        m10.hear(m10Fridge, 'AK1-AAFE13156431');
        for (var i = 0; i < 5; i++) {
          await m10.sync.tick();
        }
        expect(m10.tracker[m10Fridge]!.label, 'Galley fridge');
      },
    );

    test('changes in the same millisecond each get their own time', () async {
      final store = ReadByStore.memory();
      final keys = KeyStore();
      for (var i = 0; i < 20; i++) {
        await store.setLabel('d$i', 'Name $i');
        await keys.setSecret('d$i', '$i');
      }
      // Screens send what is newer than they last sent: a tie never left.
      expect({for (final r in store.records) r.at}, hasLength(20));
      expect({for (final r in keys.records) r.at}, hasLength(20));
    });

    test(
      'a name for one of three identical sensors lands on that one only',
      () async {
        const warm = 'A4:C1:38:DF:07:81';
        const cold = 'A4:C1:38:50:6E:3A';
        const cool = 'A4:C1:38:F9:A5:12';
        for (final mac in [warm, cold, cool]) {
          m10.hear(mac, 'LYWSD03MMC');
        }
        // The iPad hears two of them, and has learnt only one MAC (from
        // its broadcasts once its key works).
        const ipadCold = '8918B170-0000-4000-8000-6D06C31036F5';
        const ipadCool = '1D2E3F40-0000-4000-8000-000000000003';
        ipad.hear(ipadCold, 'LYWSD03MMC');
        ipad.hear(ipadCool, 'LYWSD03MMC');
        ipad.tracker[ipadCool]!.decoded = Decoded(
          protocol: 'Xiaomi MiBeacon',
          model: 'LYWSD03MMC',
          kind: DeviceKind.climate,
          readings: const [],
          info: const {'mac': cool},
        );
        await m10.sync.rename(warm, 'Outside');
        await m10.sync.rename(cool, 'Bedroom');
        await settle();
        for (var i = 0; i < 5; i++) {
          await ipad.sync.tick();
        }
        expect(ipad.tracker[ipadCool]!.label, 'Bedroom');
        // The one whose MAC the iPad does not know is never guessed.
        expect(ipad.tracker[ipadCold]!.label, isNull);
      },
    );

    test('two Victrons with their own names keep their own names', () async {
      const ipadLuna = '11111111-0000-4000-8000-000000000001';
      const ipadSol = '22222222-0000-4000-8000-000000000002';
      const m10Luna = 'C1:00:00:00:00:01';
      const m10Sol = 'C1:00:00:00:00:02';
      ipad.hear(ipadLuna, 'Luna 50');
      ipad.hear(ipadSol, 'Sol 30');
      m10.hear(m10Luna, 'Luna 50');
      m10.hear(m10Sol, 'Sol 30');
      await ipad.sync.rename(ipadSol, 'Roof 30');
      await settle();
      expect(m10.tracker[m10Sol]!.label, 'Roof 30');
      expect(m10.tracker[m10Luna]!.label, isNull);
    });

    test('a name survives a restart', () async {
      final store = ReadByStore.memory();
      await store.setLabel('x', 'Porch');
      final back = ReadByRecord.fromJson(store.records.single.toJson());
      expect(back.label, 'Porch');
      expect(back.labelAt, store.records.single.labelAt);
    });

    test('a lock from before names existed still merges', () {
      final old = ReadByRecord.fromJson({'id': 'x', 's': 'm10', 'at': 5});
      expect(old.choiceAt, 5);
      expect(old.labelAt, 0);
      expect(old.label, isNull);
    });
  });

  test('two screens that dial each other at once keep one link', () async {
    final phone = Screen(air, 'phone', 'iPhone', phone: true);
    addTearDown(phone.dispose);
    await pairThrough(air, ipad, phone);
    for (final s in [ipad, m10, phone]) {
      s.sync.dialWait = Duration.zero;
    }
    await FakeRadio.advertise(air);
    await Future.wait([
      for (final s in [ipad, m10, phone]) s.sync.tick(),
    ]);
    await settle(10);
    await Future.wait([
      for (final s in [ipad, m10, phone]) s.sync.tick(),
    ]);
    await settle(10);
    for (final s in [ipad, m10, phone]) {
      expect(s.sync.linked.length, 2, reason: s.home.me.name);
    }
  });

  test('screens report where a phone is', () async {
    final phone = Screen(air, 'phone', 'iPhone', phone: true);
    addTearDown(phone.dispose);
    air.signal = (l, h) => switch ((l.id, h.id)) {
      ('m10', 'phone') => -45,
      ('ipad', 'phone') => -72,
      _ => -50,
    };
    await pairThrough(air, ipad, phone);
    await link(air, [ipad, m10, phone]);
    await m10.sync.beacon();
    await settle();
    final where = ipad.sync.heardBy('phone');
    expect(where.map((h) => (h.by.name, h.rssi)), [
      ('M10', -45),
      ('Kitchen iPad', -72),
    ]);
  });

  test('a link that goes quiet is dropped and dialled again', () async {
    ipad.sync.linkSilence = Duration.zero;
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await ipad.sync.tick();
    expect(ipad.sync.linked, isEmpty);
    ipad.sync.linkSilence = const Duration(seconds: 40);
    await settle();
    await link(air, [ipad, m10]);
    expect(ipad.sync.linked.map((s) => s.name), ['M10']);
    expect(m10.sync.linked.map((s) => s.name), ['Kitchen iPad']);
  });

  test('a screen from another home is not linked', () async {
    final stranger = Screen(air, 'x', 'Neighbour');
    addTearDown(stranger.dispose);
    await stranger.sync.startHome('Other van');
    await link(air, [ipad, m10, stranger]);
    expect(stranger.sync.connected, isFalse);
    expect(ipad.sync.linked.map((s) => s.name), ['M10']);
  });

  test('a screen refuses to pair unless asked', () async {
    final stranger = Screen(air, 'x', 'Neighbour');
    addTearDown(stranger.dispose);
    ipad.sync.stopAdding();
    await settle();
    await FakeRadio.advertise(air);
    await stranger.sync.join(
      stranger.sync.nearby.values.firstWhere((h) => h.id == 'ipad'),
    );
    expect(stranger.home.inHome, isFalse);
    expect(stranger.sync.error, contains('not adding screens'));
  });

  test('a server that fails to start tries again', () async {
    final pad = Screen(air, 'pad2', 'Spare iPad');
    addTearDown(pad.dispose);
    pad.radio.failStarts = 1;
    pad.sync.serverRetry = Duration.zero;
    await settle();
    await pad.sync.startHome('Cabin');
    expect(pad.sync.serverError, contains('Bluetooth is unknown'));
    await pad.sync.tick();
    await settle();
    expect(pad.sync.serverError, isNull);
    expect(air.servers.keys, contains('pad2'));
  });

  group('visits', () {
    late Air air;
    late Screen ipad, m10;

    Future<void> setUpWith(Duration visitEvery) async {
      air = Air();
      ipad = Screen(air, 'ipad', 'Kitchen iPad');
      m10 = Screen(air, 'm10', 'M10', visitEvery: visitEvery);
      m10.sync
        ..visitLength = Duration.zero
        ..visitQuiet = Duration.zero;
      await ipad.sync.startHome('Van');
      await pairThrough(air, ipad, m10);
      await link(air, [m10]);
      expect(m10.sync.connected, isTrue);
    }

    tearDown(() {
      ipad.dispose();
      m10.dispose();
    });

    test('a visit swaps news, then lets go until the next turn', () async {
      await setUpWith(const Duration(seconds: 20));
      await m10.sync.tick();
      await settle();
      expect(m10.sync.connected, isFalse);
      expect(ipad.sync.connected, isFalse);
      // Both still count the other as linked, between visits.
      expect(m10.sync.touching.map((s) => s.name), ['Kitchen iPad']);
      expect(ipad.sync.touching.map((s) => s.name), ['M10']);
      expect(ipad.sync.screens.map((s) => s.name), ['Kitchen iPad', 'M10']);
      // Not again until its turn.
      await m10.sync.tick();
      await settle();
      expect(m10.sync.connected, isFalse);
    });

    test('a control waits for the screen that visits', () async {
      await setUpWith(const Duration(milliseconds: 300));
      ipad.hear(ipadFridge, 'AK1-AAFE13156431');
      m10.hear(m10Fridge, 'AK1-AAFE13156431');
      await ipad.sync.lock(ipadFridge, m10.home.me);
      await settle();
      expect(m10.sync.readBy.lockOf(m10Fridge)?.screen, 'm10');
      await m10.sync.tick();
      await settle();
      expect(m10.sync.connected, isFalse);
      final sent = ipad.connections.control(
        ipadFridge,
        const DeviceCommand('target', 39),
      );
      await settle();
      expect(m10.driver.commands, isEmpty);
      // The M10's next visit picks it up and answers before letting go.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await m10.sync.tick();
      await settle();
      await sent;
      expect(m10.driver.commands.single.value, 39);
    });
  });
}
