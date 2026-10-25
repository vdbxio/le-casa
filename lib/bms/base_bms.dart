// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// The common half of every BMS driver: notification plumbing, the
// send-and-wait-for-reply loop with retries and write-mode fallback, and
// the field decoders. Drivers subclass [BaseBms] the way aiobmsble drivers
// subclass BaseBMS, so each one stays a close, reviewable port.
//
// Differences from upstream: the connection itself is owned by Le'Casa's
// connection manager, which hands an open [GattSession] in with [attach];
// "connect" here means "start using that session". There is no keep-alive
// task, because Le'Casa connects, reads and lets go.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../ble/gatt_session.dart';
import 'bms_types.dart';
import 'bytes.dart';
import 'sample_calc.dart';

export 'bms_types.dart';
export 'bytes.dart';

/// asyncio.Event.
class AsyncEvent {
  Completer<void>? _waiter;
  bool _set = false;

  bool get isSet => _set;

  void set() {
    _set = true;
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  void clear() => _set = false;

  Future<void> wait() {
    if (_set) return Future.value();
    return (_waiter ??= Completer<void>()).future;
  }
}

/// Identity of the device a BMS instance talks to.
class BmsDevice {
  final String name;
  final String address;
  const BmsDevice(this.name, this.address);
}

typedef NotifyHandler = FutureOr<void> Function(GattChar sender, Uint8List data);

/// A characteristic given by UUID string (any form) or as a [GattChar].
typedef CharSpec = Object;

abstract class BaseBms {
  /// Retries per write mode for one request.
  static const maxRetry = 3;

  /// aiobmsble's default operation timeout (BLEAK_TIMEOUT / 4).
  static const defaultTimeout = 5.0;

  static const bleMaxAttrSize = 512;
  static const maxCellVolt = 5.906;
  static const hrsToSecs = 3600;
  static const maxTimeoutFactor = 8;

  /// Scales every timeout. Tests set it near zero; production leaves 1.
  @visibleForTesting
  static double timeScale = 1.0;

  /// Converts seconds to a scaled Duration.
  static Duration secs(num s) =>
      Duration(microseconds: (s * 1e6 * timeScale).round());

  final BmsDevice device;
  final BmsConfig cfg;
  late final String name = device.name.trimRight();

  GattSession? _client;
  GattSession? _attached;
  final List<StreamSubscription<Uint8List>> _subs = [];
  final Map<String, NotifyHandler> _handlers = {};
  final Set<String> _subscribed = {};

  /// Reassembly buffer for multi-notification frames.
  final ByteBuf frame = ByteBuf(
    (maxMsgLen > bleMaxAttrSize ? maxMsgLen : bleMaxAttrSize) * 2,
  );
  final AsyncEvent msgEvent = AsyncEvent();
  bool? _invWrMode;

  /// Shared default for drivers that size frames by a length byte.
  static const maxMsgLen = 0xFF;

  BaseBms(this.device, [BmsConfig? config]) : cfg = config ?? const BmsConfig();

  // ---- What each driver declares (aiobmsble's class attributes) --------

  /// Static info: at least `manufacturer` and `model`.
  BmsInfo get info;

  /// 128-bit UUIDs of services the BMS needs.
  List<String> get uuidServices;

  /// Characteristic for notifications (16-bit or 128-bit UUID string).
  String get uuidRx;

  /// Characteristic to write requests to.
  String get uuidTx;

  /// Values that must not be derived even when they could be.
  Set<String> get rawValues => const {};

  /// Operation timeout in seconds (aiobmsble's TIMEOUT).
  double get timeout => defaultTimeout;

  /// Per-attempt wait, so all retries of one mode fit into [timeout].
  double get retryTimeout => defaultTimeout / ((1 << maxRetry) - 1);

  /// Whether the BMS accepts a secret (PIN, password).
  bool get acceptSecret => false;

  /// The connected session. Throws if not connected.
  GattSession get client => _client ?? (throw StateError('BMS not connected'));

  bool get isConnected => _client != null;

  String get bmsId => '${info['manufacturer']} ${info['model']}';

  // ---- Driver hooks ------------------------------------------------------

  /// Handles one notification from [uuidRx].
  FutureOr<void> notificationHandler(GattChar sender, Uint8List data);

  /// Reads one sample. Called with the connection set up.
  Future<BmsSample> asyncUpdate();

  /// Sets up the connection: by default subscribes to [uuidRx].
  Future<void> initConnection([CharSpec? charNotify]) async {
    frame.clear();
    msgEvent.clear();
    await startNotify(charNotify ?? uuidRx, notificationHandler);
  }

  /// Runs before the connection is released.
  Future<void> onDisconnect(bool reset) async {}

  /// Reads the Device Information service (0x180A). Drivers override this
  /// when the BMS reports versions in its own protocol.
  Future<BmsInfo> fetchDeviceInfo() async {
    final result = <String, String>{};
    const chars = [
      ('2a24', 'model'),
      ('2a25', 'serial_number'),
      ('2a26', 'fw_version'),
      ('2a27', 'hw_version'),
      ('2a28', 'sw_version'),
      ('2a29', 'manufacturer'),
    ];
    for (final (uuid, key) in chars) {
      final c = client.find(uuid);
      if (c == null) continue;
      try {
        final v = await client.read(c);
        if (v.isNotEmpty) result[key] = b2str(v);
      } catch (e) {
        debugPrint('bms: $name: reading $key failed: $e');
      }
    }
    return result;
  }

  // ---- Public API ----------------------------------------------------------

  /// Hands an open, service-discovered session to this BMS. The next
  /// [update] or [deviceInfo] sets it up.
  void attach(GattSession session) => _attached = session;

  /// Reads one sample, deriving missing values unless [raw].
  Future<BmsSample> update({bool raw = false}) async {
    await _connect();
    final data = await asyncUpdate();
    if (!raw) addMissingValues(data, rawValues);
    return data;
  }

  Future<BmsInfo> deviceInfo() async {
    final disconnectAfter = !isConnected;
    await _connect();
    final info = await fetchDeviceInfo();
    if (disconnectAfter) await disconnect();
    return info;
  }

  /// Stops using the session. The caller still owns closing the link.
  Future<void> disconnect({bool reset = false}) async {
    msgEvent.clear();
    if (_client != null) {
      try {
        await onDisconnect(reset);
      } catch (e) {
        debugPrint('bms: $name: disconnect hook failed: $e');
      }
    }
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _handlers.clear();
    _subscribed.clear();
    _client = null;
    if (reset) _invWrMode = null;
  }

  Future<void> _connect() async {
    if (_client != null) return;
    final s = _attached;
    if (s == null) throw StateError('No session attached to $name');
    _client = s;
    try {
      await initConnection();
    } on TimeoutException {
      await disconnect();
      rethrow;
    }
  }

  // ---- Helpers for drivers -----------------------------------------------

  /// Resolves a UUID string or [GattChar] to a characteristic.
  GattChar char(CharSpec spec) {
    if (spec is GattChar) return spec;
    final uuid = spec as String;
    return client.find(uuid) ??
        (throw UnsupportedDeviceException('No characteristic $uuid on $name'));
  }

  /// Subscribes [handler] to notifications of [spec]. Subscribing again
  /// replaces the handler.
  Future<void> startNotify(CharSpec spec, NotifyHandler handler) async {
    final c = char(spec);
    final key = '${c.uuid}#${identityHashCode(c)}';
    _handlers[key] = handler;
    if (!_subscribed.add(key)) return;
    final stream = await client.subscribe(c);
    _subs.add(
      stream.listen((data) {
        final h = _handlers[key];
        if (h == null) return;
        try {
          final r = h(c, data);
          if (r is Future) {
            r.catchError((Object e) => debugPrint('bms: $name: handler: $e'));
          }
        } catch (e, st) {
          debugPrint('bms: $name: notification handler failed: $e\n$st');
        }
      }),
    );
  }

  /// Stops delivering notifications of [spec] to its handler.
  Future<void> stopNotify(CharSpec spec) async {
    final c = char(spec);
    _handlers.remove('${c.uuid}#${identityHashCode(c)}');
  }

  bool _wrResponse(GattChar c) => c.canWrite;

  Future<void> _sendMsg(
    List<int> data,
    int maxSize,
    GattChar c,
    bool invWrMode,
  ) async {
    final chunk = maxSize > 0 ? maxSize : data.length;
    for (var i = 0; i < data.length; i += chunk) {
      final end = i + chunk > data.length ? data.length : i + chunk;
      await client.write(
        c,
        Uint8List.fromList(data.sublist(i, end)),
        withResponse: _wrResponse(c) != invWrMode,
      );
    }
  }

  /// Sends [data] and waits until the notification handler sets
  /// [msgEvent]. Retries with growing timeouts, then once more in the
  /// other write mode. Throws [TimeoutException] when nothing valid came.
  Future<void> awaitMsg(
    List<int> data, {
    CharSpec? char,
    bool waitForNotify = true,
    int maxSize = 0,
  }) async {
    final c = this.char(char ?? uuidTx);
    final modes = _invWrMode == null ? [false, true] : [_invWrMode!];
    for (final inv in modes) {
      try {
        msgEvent.clear();
        for (var attempt = 0; attempt < maxRetry; attempt++) {
          await _sendMsg(data, maxSize, c, inv);
          if (!waitForNotify) return;
          final factor = (1 << attempt) < maxTimeoutFactor
              ? (1 << attempt)
              : maxTimeoutFactor;
          try {
            await waitEvent(secs(retryTimeout * factor));
          } on TimeoutException {
            continue;
          }
          _invWrMode = inv;
          return;
        }
      } on UnsupportedDeviceException {
        rethrow;
      } on TimeoutException {
        rethrow;
      } catch (e) {
        if (e is StateError) rethrow;
        debugPrint('bms: $name: TX request error: $e');
      }
    }
    throw TimeoutException('$name did not answer');
  }

  /// Waits for [msgEvent], then clears it. With a [timeout] it throws
  /// [TimeoutException] and leaves the event alone, like asyncio.wait_for
  /// cancelling the wait.
  Future<void> waitEvent([Duration? timeout]) async {
    final f = msgEvent.wait();
    await (timeout == null ? f : f.timeout(timeout));
    msgEvent.clear();
  }

  /// `asyncio.wait_for(self._wait_event(), timeout=seconds)`.
  Future<void> waitEventFor(double seconds) => waitEvent(secs(seconds));

  /// `asyncio.sleep(seconds)`.
  Future<void> sleep(double seconds) => Future.delayed(secs(seconds));

  /// Logs when [calc] over `data[dicSlice]` does not match the expected
  /// value, given as a slice of [data] or as an int.
  bool checkIntegrity(
    List<int> data,
    int Function(List<int>) calc,
    (int?, int?) dicSlice,
    Object expected, {
    bool little = false,
  }) {
    final got = calc(data.sl(dicSlice.$1, dicSlice.$2));
    final exp = expected is (int?, int?)
        ? intFrom(data.sl(expected.$1, expected.$2), little: little)
        : expected as int;
    if (got != exp) {
      debugPrint(
        'bms: $name: invalid checksum 0x${exp.toRadixString(16)} != '
        '0x${got.toRadixString(16)}',
      );
      return false;
    }
    return true;
  }

  // ---- Static decoding helpers (aiobmsble BaseBMS statics) ---------------

  /// Assembles a MODBUS request with CRC.
  static Uint8List cmdModbus({
    int devId = 0,
    int fct = 3,
    int addr = 0,
    int count = 1,
  }) {
    final f = [
      devId & 0xFF,
      fct & 0xFF,
      (addr >> 8) & 0xFF,
      addr & 0xFF,
      (count >> 8) & 0xFF,
      count & 0xFF,
    ];
    final crc = crcModbus(f);
    return Uint8List.fromList([...f, crc & 0xFF, crc >> 8]);
  }

  /// Decodes [fields] out of one message, or out of a map of messages
  /// keyed by [BmsDp.idx].
  static BmsSample decodeData(
    List<BmsDp> fields,
    Object data, {
    bool little = false,
    int start = 0,
  }) {
    final result = <String, Object?>{};
    for (final f in fields) {
      final List<int> msg;
      if (data is Map<int, List<int>>) {
        final m = data[f.idx];
        if (m == null) continue;
        msg = m;
      } else {
        msg = data as List<int>;
      }
      final pos = start + f.pos;
      final end = pos + f.size;
      if (pos < 0 || end > msg.length) continue;
      if (f.fctBytes != null) {
        result[f.key] = f.fctBytes!(msg.sublist(pos, end));
        continue;
      }
      result[f.key] = f.fct(
        intFrom(msg.sublist(pos, end), little: little, signed: f.signed),
      );
    }
    return result;
  }

  /// Like [decodeData] for one pack, without range checks.
  static BmsSample decodePack(
    List<BmsDp> fields,
    List<int> data, {
    bool little = false,
    int start = 0,
  }) => {
    for (final f in fields)
      f.key: f.fct(
        intFrom(
          data.sl(start + f.pos, start + f.pos + f.size),
          little: little,
          signed: f.signed,
        ),
      ),
  };

  /// Cell voltages; zero readings are dropped, like upstream.
  static List<double> cellVoltages(
    List<int> data, {
    required int cells,
    required int start,
    int size = 2,
    int gap = 0,
    bool little = false,
    int divider = 1000,
  }) {
    final out = <double>[];
    for (var idx = 0; idx < cells; idx++) {
      final p = start + idx * (size + gap);
      if (data.length < p + size) continue;
      final v = intFrom(data.sublist(p, p + size), little: little);
      if (v != 0) out.add(v / divider);
    }
    return out;
  }

  /// Temperatures; with an [offset], zero raw values mean "no sensor".
  static List<TempSensor> tempValues(
    List<int> data, {
    required int start,
    int values = 1,
    int size = 2,
    int gap = 0,
    bool little = false,
    bool signed = true,
    num offset = 0,
    int divider = 1,
    List<TempType> types = const [],
  }) {
    final out = <TempSensor>[];
    for (var idx = 0; idx < values; idx++) {
      final p = start + idx * (size + gap);
      if (data.length < p + size) continue;
      final v = intFrom(data.sublist(p, p + size), little: little, signed: signed);
      if (v != 0 || offset == 0) {
        out.add(
          TempSensor(
            (v - offset) / divider,
            idx < types.length ? types[idx] : TempType.generic,
          ),
        );
      }
    }
    return out;
  }

  /// Derives missing values and sets `problem` from sanity checks.
  static void addMissingValues(
    BmsSample data, [
    Set<String> rawValues = const {},
  ]) {
    if (data.isEmpty) return;
    deriveMissingFields(data, rawValues);
    final level = (data['battery_level'] as num?) ?? 0;
    final cells = ((data['cell_voltages'] as List?) ?? const []).cast<num>();
    final pc = data['problem_code'];
    data['problem'] = [
      data['problem'] == true,
      pc != null && pc != 0 && pc != false,
      data['voltage'] != null && (data['voltage'] as num) <= 0,
      cells.any((v) => v <= 0 || v > maxCellVolt),
      ((data['delta_voltage'] as num?) ?? 0) > maxCellVolt,
      data['cycle_charge'] != null && (data['cycle_charge'] as num) <= 0,
      level > 100,
    ].any((e) => e);
  }
}
