// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// Dometic Büttner BMS. Three channel pairs: A carries data, B and C are a
// keep-alive handshake the BMS insists on before it streams.

import 'dart:async';
import 'dart:typed_data';

import '../../ble/gatt_session.dart';
import '../base_bms.dart';
import '../spec.dart';

class DometicBms extends BaseBms {
  static final spec = BmsSpec(
    module: 'dometic_bms',
    info: const {'manufacturer': 'Dometic', 'model': 'Büttner BMS'},
    matchers: const [
      MatcherPattern(manufacturerId: 2117, manufacturerDataStart: [0x14, 0x85]),
    ],
    create: DometicBms.new,
    acceptSecret: true,
    secretHint: 'The PIN set for the battery in the Dometic app.',
  );

  static const _chATx = '00000001-0000-1000-8000-008025000000';
  static const _chARx = '00000002-0000-1000-8000-008025000000';
  static const _chBTx = '00000003-0000-1000-8000-008025000000';
  static const _chBRx = '00000004-0000-1000-8000-008025000000';
  static const _chCTx = '00000009-0000-1000-8000-008025000000';
  static const _chCRx = '0000000a-0000-1000-8000-008025000000';

  static const _head = [0x23, 0x85];
  static const _frameLen = 8;
  static const _gatherTimeout = 20.0;
  static final _fields = <BmsDp>[
    BmsDp('voltage', 4, 2, false, (x) => x / 100, 0x2),
    BmsDp(
      'current',
      6,
      2,
      false,
      (x) => (x <= 32767 ? x : 32767 - x) / 100,
      0x2,
    ),
    BmsDp('design_capacity', 4, 4, false, (x) => x, 0x7),
    BmsDp('battery_level', 4, 1, false, (x) => x, 0xB),
    BmsDp(
      'temp_values',
      4,
      2,
      false,
      (x) => [TempSensor((x - 500) / 10)],
      0x0C,
    ),
    BmsDp('cycle_capacity', 4, 2, false, (x) => x, 0x36),
    BmsDp('battery_health', 4, 1, false, (x) => x, 0xE),
  ];
  // design capacity (0x7) is not waited for; it does not change
  static final Set<int> _cmds = {
    for (final f in _fields)
      if (f.idx != 0x7) f.idx,
    0x56,
    0x57,
  };

  final Map<int, Map<int, List<int>>> _dataFinal = {};
  List<int> _expReply = const [];
  final _disconnectEvent = AsyncEvent();
  final _chBEvent = AsyncEvent();
  final _chCEvent = AsyncEvent();
  int _kaResp = 0xFF;
  final Map<int, List<int>> _designCap = {};
  final Set<int> _knownPacks = {};

  DometicBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  bool get acceptSecret => true;
  @override
  List<String> get uuidServices => [uuid16(0xFEFB), uuid16(0x2345)];
  @override
  String get uuidRx => _chARx;
  @override
  String get uuidTx => _chATx;

  /// Keep-alive (upstream runs it every 24 s on a held connection).
  Future<void> alive() async {
    await awaitMsg(ascii('APP+NET'), waitForNotify: false);
    await awaitMsg([_kaResp], char: _chBTx, waitForNotify: false);
    _kaResp ^= 0x20;
  }

  Future<void> _subscribeAndWait(String uuid, AsyncEvent event) async {
    await startNotify(uuid, _keepAliveHandler);
    event.clear();
    await event.wait().timeout(BaseBms.secs(timeout));
  }

  @override
  Future<void> initConnection([CharSpec? charNotify]) async {
    _kaResp = 0xFF;
    _disconnectEvent.clear();
    await _subscribeAndWait(_chCRx, _chCEvent);
    await _subscribeAndWait(_chBRx, _chBEvent);
    await super.initConnection(charNotify);

    _expReply = ascii('MST+AEN');
    await awaitMsg([
      ...ascii('APP+AEN'),
      if (cfg.secret.isNotEmpty) ...ascii('=${cfg.secret}'),
    ]);
    _expReply = ascii('MST+NET=');
    await awaitMsg(ascii('APP+NET'));
    msgEvent.clear();
  }

  Future<void> _keepAliveHandler(GattChar sender, Uint8List data) async {
    if (data.isEmpty) return;
    switch (sender.uuid) {
      case _chBRx:
        await awaitMsg([_kaResp], char: _chBTx, waitForNotify: false);
        _kaResp ^= 0x20;
        _chBEvent.set();
      case _chCRx:
        await awaitMsg(data, char: _chCTx, waitForNotify: false);
        _chCEvent.set();
    }
  }

  @override
  Future<void> notificationHandler(GattChar sender, Uint8List data) async {
    if (bytesEq(data, ascii('+++'))) {
      _disconnectEvent.set();
      return;
    }
    if (_expReply.isNotEmpty && data.startsWithBytes(_expReply)) {
      _expReply = const [];
      msgEvent.set();
      return;
    }
    if (!data.startsWithBytes(_head)) return;
    if (data.length != _frameLen) return;

    _dataFinal.putIfAbsent(data[2], () => {})[data[3]] = Uint8List.fromList(
      data,
    );
    final complete = {
      for (final e in _dataFinal.entries)
        if (_cmds.every(e.value.containsKey)) e.key,
    };
    if (complete.length == _dataFinal.length &&
        complete.containsAll(_dataFinal.keys) &&
        complete.containsAll(_knownPacks) &&
        complete.isNotEmpty) {
      msgEvent.set();
    } else {
      // e.g. another pack started reporting: the set is incomplete again
      msgEvent.clear();
    }
  }

  static List<double> _cellV(Map<int, List<int>> data, {required int cells}) =>
      [
        for (var i = 0; i < cells ~/ 2; i++)
          ...BaseBms.cellVoltages(data[0x56 + i]!, cells: 2, start: 4),
      ];

  @override
  Future<BmsSample> asyncUpdate() async {
    if (_disconnectEvent.isSet) {
      await disconnect();
      if (!msgEvent.isSet) {
        _dataFinal.clear();
        throw const FormatException('BMS data incomplete');
      }
    }
    if (!msgEvent.isSet) {
      _dataFinal.clear();
      _expReply = ascii('MST+DCO=');
      await awaitMsg(ascii('APP+RDN=1'));
      msgEvent.clear();
    }
    await waitEventFor(_gatherTimeout);

    try {
      for (final e in _dataFinal.entries) {
        final data = e.value;
        final cap = data[0x7] ?? _designCap[e.key];
        if (!_cmds.every(data.containsKey) || cap == null) {
          throw const FormatException('BMS data incomplete.');
        }
        _designCap[e.key] = data[0x7] = cap;
      }
      _knownPacks.addAll(_dataFinal.keys);

      final result = <String, Object?>{'pack_count': _dataFinal.length};
      final packs = <BmsSample>[];
      for (final pack in _dataFinal.keys.toList()..sort()) {
        final r = BaseBms.decodeData(_fields, _dataFinal[pack]!);
        r['cell_voltages'] = _cellV(_dataFinal[pack]!, cells: 4);
        packs.add(r);
      }
      if (packs.isNotEmpty) result['packs'] = packs;
      return result;
    } finally {
      _dataFinal.clear();
      msgEvent.clear();
    }
  }
}
