import 'dart:async';

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
import 'package:lecasa/sync/sync_service.dart';

import '../fake_session.dart';
import 'pipe.dart';

/// The air between fake radios: hubs advertise here, members connect.
class Air {
  final hubs = <String, FakeRadio>{};
  final listeners = <FakeRadio>[];
}

class FakeRadio implements SyncRadio {
  final Air air;
  final String id;
  final _incoming = StreamController<MessageLink>.broadcast();
  final _sightings = StreamController<HubSighting>.broadcast();
  String? tag;

  /// How many more startHub calls fail, like iOS before Bluetooth is up.
  int failStarts = 0;

  FakeRadio(this.air, this.id) {
    air.listeners.add(this);
  }

  /// Every listener hears every hub, as a scan would.
  static Future<void> advertise(Air air) async {
    for (final h in air.hubs.values) {
      for (final l in air.listeners) {
        if (l != h) {
          l._sightings.add(HubSighting(h.id, h.tag, -50, DateTime.now()));
        }
      }
    }
    await pumpEventQueue();
  }

  @override
  Future<void> startHub(String tag) async {
    if (failStarts > 0) {
      failStarts--;
      throw StateError('Bluetooth is unknown');
    }
    this.tag = tag;
    air.hubs[id] = this;
  }

  @override
  Future<void> stopHub() async => air.hubs.remove(id);

  @override
  Stream<MessageLink> get incoming => _incoming.stream;

  @override
  Stream<HubSighting> get sightings => _sightings.stream;

  @override
  Future<MessageLink> connect(HubSighting hub) async {
    final h = air.hubs[hub.id];
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

  Screen(Air air, String id, String name)
    : home = HomeStore.memory(id, name),
      radio = FakeRadio(air, id) {
    connections = ConnectionManager(
      tracker,
      open: (_) async => FakeSession(characteristics: const []),
      drivers: GattDriverRegistry([driver]),
      tick: const Duration(days: 1),
    );
    sync = SyncService(
      home: home,
      tracker: tracker,
      keys: keys,
      connections: connections,
      radio: radio,
    )..start();
    keys.label = (id) =>
        (name: tracker[id]?.latest.name, mac: tracker[id]?.latest.macString);
  }

  void hear(String id, String name) {
    final adv = RawAdvertisement(
      id: id,
      rssi: -60,
      seenAt: DateTime.now(),
      name: name,
      mac: parseMac(id),
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
    ipad.sync.startAdding();
    await FakeRadio.advertise(air);
    final hub = m10.sync.nearby.values.single;
    final join = m10.sync.join(hub);
    await settle();
    expect(ipad.sync.prompt, isNotNull);
    expect(m10.sync.prompt?.code, ipad.sync.prompt!.code);
    ipad.sync.answer(true);
    m10.sync.answer(true);
    await join;
    expect(m10.home.role, SyncRole.member);
    expect(m10.home.key, ipad.home.key);
    await FakeRadio.advertise(air);
    await m10.sync.tick();
    await settle();
    expect(m10.sync.connected, isTrue);
    expect(ipad.sync.members.single.name, 'M10');
  });

  tearDown(() {
    ipad.dispose();
    m10.dispose();
  });

  test('the hub screen list reaches members', () {
    expect(m10.sync.screens.map((s) => s.name), ['Kitchen iPad', 'M10']);
    expect(m10.home.hubName, 'Kitchen iPad');
  });

  test(
    'a reading the hub takes shows on the member, which backs off',
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

  test('a screen set not to hold connections leaves devices alone', () async {
    await m10.home.setHoldsDevices(false);
    m10.hear(m10Fridge, 'AK1-AAFE13156431');
    await m10.connections.pump();
    expect(m10.connections[m10Fridge]!.lastAttempt, isNull);
    // Outside a home it reads everything itself again.
    await m10.sync.leave();
    await m10.connections.pump();
    expect(m10.connections[m10Fridge]!.lastOk, isNotNull);
  });

  test('a device the member never heard still shows up', () async {
    ipad.hear(ipadFridge, 'AK1-AAFE13156431');
    await ipad.connections.readNow(ipadFridge);
    await ipad.sync.tick();
    await settle();
    final d = m10.tracker[ipadFridge]!;
    expect(d.remoteOnly, isTrue);
    expect(d.title, 'Fridge');
  });

  test('a control on the member runs on the hub', () async {
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
          contains('Read over connection'),
        ),
      ),
    );
    await settle();
    await check;
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

  test('a third screen gets everything through the hub', () async {
    final phone = Screen(air, 'phone', 'iPhone');
    addTearDown(phone.dispose);
    ipad.sync.startAdding();
    await FakeRadio.advertise(air);
    final join = phone.sync.join(phone.sync.nearby.values.single);
    await settle();
    ipad.sync.answer(true);
    phone.sync.answer(true);
    await join;
    await FakeRadio.advertise(air);
    await phone.sync.tick();
    await settle();
    // A reading the M10 takes travels M10 -> hub -> phone.
    m10.hear(m10Fridge, 'AK1-AAFE13156431');
    await m10.connections.readNow(m10Fridge);
    await m10.sync.tick();
    await settle();
    expect(phone.tracker[m10Fridge]?.polledBy, 'M10');
    expect(ipad.tracker[m10Fridge]?.polledBy, 'M10');
    // And a control from the phone travels phone -> hub -> M10.
    final done = phone.connections.control(
      m10Fridge,
      const DeviceCommand('target', 44),
    );
    await settle(10);
    await done;
    expect(m10.driver.commands.single.value, 44);
  });

  test('a screen from another home is turned away', () async {
    final stranger = Screen(air, 'x', 'Neighbour');
    addTearDown(stranger.dispose);
    await stranger.sync.startHome('Other van');
    // Pretend the neighbour's hub went away and m10 needs to reconnect.
    await ipad.sync.leave();
    await settle();
    await FakeRadio.advertise(air);
    await m10.sync.tick();
    await settle();
    expect(m10.sync.connected, isFalse);
    expect(stranger.sync.members, isEmpty);
  });

  test('the hub refuses to pair unless asked', () async {
    final stranger = Screen(air, 'x', 'Neighbour');
    addTearDown(stranger.dispose);
    ipad.sync.stopAdding();
    await FakeRadio.advertise(air);
    await stranger.sync.join(
      stranger.sync.nearby.values.firstWhere((h) => h.id == 'ipad'),
    );
    expect(stranger.home.role, SyncRole.alone);
    expect(stranger.sync.error, contains('not adding screens'));
  });

  test('a hub that fails to start tries again', () async {
    final pad = Screen(air, 'pad2', 'Spare iPad');
    addTearDown(pad.dispose);
    pad.radio.failStarts = 1;
    pad.sync.hubRetry = Duration.zero;
    await settle();
    await pad.sync.startHome('Cabin');
    expect(pad.sync.connected, isFalse);
    expect(pad.sync.error, contains('Bluetooth is unknown'));
    await pad.sync.tick();
    await settle();
    expect(pad.sync.connected, isTrue);
    expect(pad.sync.error, isNull);
  });
}
