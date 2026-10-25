// Runs every Dart BMS driver against the GATT traces recorded from
// aiobmsble's own test suite (tool/aiobmsble/bmsrec.py) and checks that it
// sends the same requests and returns the same samples.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/bms/base_bms.dart';
import 'package:lecasa/bms/registry.dart';

import 'trace_session.dart';

const _errorTypes = {
  'TimeoutError': 'TimeoutException',
  'ValueError': 'FormatException',
  'PermissionError': 'BmsPermissionException',
  'BufferError': 'BufferException',
};

String _errName(Object e) => switch (e) {
  TimeoutException() => 'TimeoutException',
  FormatException() => 'FormatException',
  BmsPermissionException() => 'BmsPermissionException',
  BufferException() => 'BufferException',
  _ => e.runtimeType.toString(),
};

/// Compares a Dart value with the JSON form of a Python value.
String? diff(Object? got, Object? want, String path) {
  if (want is Map && want.containsKey('big')) {
    final w = BigInt.parse(want['big'] as String).toUnsigned(64);
    if (got is BigInt) {
      return got == BigInt.parse(want['big'] as String)
          ? null
          : '$path: got $got, want ${want['big']}';
    }
    final g = got is int ? BigInt.from(got).toUnsigned(64) : null;
    return g == w ? null : '$path: got $got, want ${want['big']}';
  }
  if (want is Map && want.containsKey('t') && want.containsKey('k')) {
    if (got is! TempSensor) return '$path: got $got, want TempSensor';
    final t = (want['t'] as num).toDouble();
    if ((got.value - t).abs() > 1e-6 || got.type.index != want['k']) {
      return '$path: got $got, want ($t, ${TempType.values[want['k'] as int]})';
    }
    return null;
  }
  if (want is Map) {
    if (got is! Map) return '$path: got $got, want map';
    final keys = {...want.keys, ...got.keys};
    for (final k in keys) {
      if (!want.containsKey(k)) return '$path.$k: unexpected ${got[k]}';
      if (!got.containsKey(k)) return '$path.$k: missing, want ${want[k]}';
      final d = diff(got[k], want[k], '$path.$k');
      if (d != null) return d;
    }
    return null;
  }
  if (want is List) {
    if (got is! List) return '$path: got $got, want list';
    if (got.length != want.length) {
      return '$path: got ${got.length} items $got, want ${want.length} $want';
    }
    for (var i = 0; i < want.length; i++) {
      final d = diff(got[i], want[i], '$path[$i]');
      if (d != null) return d;
    }
    return null;
  }
  if (want is bool || got is bool) {
    return got == want ? null : '$path: got $got, want $want';
  }
  if (want is num) {
    final g = got is TempSensor ? got.value : got;
    if (g is! num) return '$path: got $got, want $want';
    final tol = 1e-6 + 1e-9 * want.abs();
    return (g - want).abs() <= tol ? null : '$path: got $g, want $want';
  }
  if (got is BmsMode && want is int) {
    return got.code == want ? null : '$path: got $got, want $want';
  }
  return got == want ? null : '$path: got $got, want $want';
}

Future<String?> replay(Map<String, dynamic> trace) async {
  final b = (trace['bms'] as List).first as Map<String, dynamic>;
  final spec = bmsSpecByModule(b['module'] as String)!;
  final events = (trace['events'] as List).cast<Map<String, dynamic>>();
  final session = TraceSession(events);
  final bms = spec.create(
    BmsDevice((b['name'] as String?) ?? 'MockBLEDevice', b['address'] as String),
    BmsConfig(secret: (b['secret'] as String?) ?? ''),
  );
  Object? got;
  Object? err;
  for (var i = 0; i < events.length; i++) {
    final e = events[i];
    if (TraceSession.markers.contains(e['e'])) session.enter(i);
    switch (e['e']) {
      case 'update':
        if (!bms.isConnected) bms.attach(session);
        got = null;
        err = null;
        try {
          got = await bms.update(raw: e['raw'] == true);
        } catch (x) {
          err = x;
        }
      case 'info_req':
        if (!bms.isConnected) bms.attach(session);
        got = null;
        err = null;
        try {
          got = await bms.deviceInfo();
        } catch (x) {
          err = x;
        }
      case 'disconnect':
        await bms.disconnect();
      case 'result' || 'info':
        if (session.mismatches.isNotEmpty) {
          return 'trace: ${session.mismatches.first}';
        }
        if (err != null) return 'threw ${_errName(err)}: $err';
        final d = diff(got, e['v'], e['e'] as String);
        if (d != null) return d;
      case 'error':
        final want = _errorTypes[e['t']] ?? e['t'];
        if (err == null) {
          return 'expected ${e['t']}, got $got'
              '${session.mismatches.isEmpty ? '' : ' (${session.mismatches.first})'}';
        }
        if (_errName(err) != want) return 'expected $want, threw ${_errName(err)}: $err';
    }
  }
  return null;
}

/// Traces that depend on what a test monkeypatched inside the Python BMS or
/// on asyncio scheduling between calls, which a replay cannot reproduce.
const _skip = <String, String>{
  'dometic_bms test_bms_disconnect[True]': 'patches _GATHER_TIMEOUT',
  'dometic_bms test_keep_alive_handler_broken_sender':
      'mock notifies from a characteristic the BMS never subscribed',
  'dometic_bms test_update_with_preset_event':
      'relies on asyncio.sleep(0) between two updates',
  'pwrxtreme_bms test_device_info_decode_error': 'monkeypatches _await_msg',
  'pwrxtreme_bms test_device_info_timeout': 'monkeypatches _await_msg',
};

void main() {
  BaseBms.timeScale = 0.01;
  debug = Platform.environment['TRACE_DEBUG'] == '1';
  final dir = Directory('test/bms/vectors');
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('_bms.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final f in files) {
    final module = f.uri.pathSegments.last.replaceAll('.json', '');
    final spec = bmsSpecByModule(module);
    group(module, () {
      final traces = (jsonDecode(f.readAsStringSync()) as List)
          .cast<Map<String, dynamic>>();
      for (final t in traces) {
        final name = (t['tests'] as List).first as String;
        test(name, () async {
          final r = await replay(t);
          expect(r, isNull, reason: (t['tests'] as List).join(', '));
        }, skip: spec == null ? 'not ported yet' : _skip['$module $name']);
      }
    });
  }
}
