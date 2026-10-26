import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lecasa/sync/crypto.dart';
import 'package:lecasa/sync/framing.dart';
import 'package:lecasa/sync/session.dart';

import 'pipe.dart';

const hubId = ScreenId('h1', 'Kitchen iPad');
const memberId = ScreenId('m1', 'M10');

void main() {
  group('framing', () {
    test('splits and joins messages of any size', () async {
      final (a, b) = messagePipe(maxChunk: 7);
      final got = <Uint8List>[];
      b.messages.listen(got.add);
      final msgs = [
        Uint8List(0),
        Uint8List.fromList([1]),
        Uint8List.fromList(List.generate(6, (i) => i)),
        Uint8List.fromList(List.generate(1000, (i) => i & 0xff)),
      ];
      for (final m in msgs) {
        await a.send(m);
      }
      await pumpEventQueue();
      expect(got, msgs);
    });
  });

  group('crypto', () {
    test('both sides of an ECDH agree', () {
      final a = EphemeralKey.generate();
      final b = EphemeralKey.generate();
      expect(a.agree(b.public), b.agree(a.public));
      expect(a.public.length, 65);
    });

    test('sealed messages open once, and only with the right key', () {
      final k = randomBytes(32);
      final tx = SealKey(k);
      final rx = SealKey(k);
      final m1 = tx.seal(Uint8List.fromList(utf8.encode('hello')));
      expect(utf8.decode(rx.open(m1)), 'hello');
      expect(() => rx.open(m1), throwsFormatException, reason: 'replay');
      final m2 = tx.seal(Uint8List.fromList([1, 2, 3]));
      m2[m2.length - 1] ^= 1;
      expect(() => rx.open(m2), throwsFormatException, reason: 'tampered');
      expect(
        () => SealKey(randomBytes(32)).open(tx.seal(Uint8List(4))),
        throwsFormatException,
      );
    });

    test('pairing code is six digits and depends on every input', () {
      final z = Uint8List(32);
      final p = Uint8List(65);
      final n = Uint8List(16);
      final c = pairingCode(
        shared: z,
        clientPublic: p,
        hubPublic: p,
        clientNonce: n,
        hubNonce: n,
      );
      expect(c, matches(RegExp(r'^\d{6}$')));
      final n2 = Uint8List(16)..[0] = 1;
      expect(
        pairingCode(
          shared: z,
          clientPublic: p,
          hubPublic: p,
          clientNonce: n,
          hubNonce: n2,
        ),
        isNot(c),
      );
    });
  });

  group('pairing', () {
    test('both people confirm: member gets the home key', () async {
      final homeKey = randomBytes(32);
      final (m, h) = messagePipe();
      String? hubCode, memberCode;
      ScreenId? paired;
      final hub = SyncSession.accept(
        h,
        hubId,
        homeKey: homeKey,
        homeName: 'Van',
        confirm: (code, peer, _) async {
          hubCode = code;
          expect(peer, memberId);
          return true;
        },
        onPaired: (s) => paired = s,
      );
      final joined = await SyncSession.pair(m, memberId, (code, peer, _) async {
        memberCode = code;
        expect(peer.name, 'Kitchen iPad');
        return true;
      });
      expect(await hub, isNull);
      expect(joined.key, homeKey);
      expect(joined.name, 'Van');
      expect(hubCode, memberCode);
      expect(paired, memberId);
    });

    test('hub says the codes differ: member gets nothing', () async {
      final (m, h) = messagePipe();
      final hub = SyncSession.accept(
        h,
        hubId,
        homeKey: randomBytes(32),
        homeName: 'Van',
        confirm: (_, _, _) async => false,
      );
      final member = SyncSession.pair(m, memberId, (_, _, abandoned) async {
        // Wait like a person would; the hub's "no" closes the link.
        await abandoned;
        return true;
      });
      expect(await hub, isNull);
      await h.close();
      await expectLater(member, throwsA(isA<SyncRefused>()));
    });

    test('member says no: hub prompt is abandoned', () async {
      final (m, h) = messagePipe();
      var hubAbandoned = false;
      final hub = SyncSession.accept(
        h,
        hubId,
        homeKey: randomBytes(32),
        homeName: 'Van',
        confirm: (_, _, abandoned) async {
          await abandoned;
          hubAbandoned = true;
          return true;
        },
      );
      await expectLater(
        SyncSession.pair(m, memberId, (_, _, _) async => false),
        throwsA(isA<SyncRefused>()),
      );
      expect(await hub, isNull);
      expect(hubAbandoned, isTrue);
    });

    test('hub not adding screens refuses', () async {
      final (m, h) = messagePipe();
      final hub = SyncSession.accept(
        h,
        hubId,
        homeKey: randomBytes(32),
        homeName: 'Van',
      );
      await expectLater(
        SyncSession.pair(m, memberId, (_, _, _) async => true),
        throwsA(isA<SyncRefused>()),
      );
      expect(await hub, isNull);
    });

    test('the home key never crosses the air in the clear', () async {
      final homeKey = randomBytes(32);
      final (a, b) = PipeEnd.pair(maxChunk: 200);
      final hub = SyncSession.accept(
        MessageLink(b),
        hubId,
        homeKey: homeKey,
        homeName: 'Van',
        confirm: (_, _, _) async => true,
      );
      await SyncSession.pair(MessageLink(a), memberId, (_, _, _) async => true);
      await hub;
      final air = [...a.sent, ...b.sent].expand((c) => c).toList();
      final keyHex = homeKey
          .map((x) => x.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(utf8.decode(air, allowMalformed: true), isNot(contains(keyHex)));
      expect(_contains(air, homeKey), isFalse);
    });
  });

  group('sessions', () {
    test('same home: sealed messages both ways', () async {
      final homeKey = randomBytes(32);
      final (m, h) = messagePipe();
      final hubF = SyncSession.accept(
        h,
        hubId,
        homeKey: homeKey,
        homeName: 'Van',
      );
      final member = await SyncSession.connect(m, memberId, homeKey);
      final hub = (await hubF)!;
      expect(hub.peer, memberId);
      expect(member.peer.name, 'Kitchen iPad');
      final toHub = hub.messages.first;
      final toMember = member.messages.first;
      await member.send({'t': 'state', 'n': 1});
      await hub.send({'t': 'keys', 'big': 'x' * 3000});
      expect((await toHub)['n'], 1);
      expect(((await toMember)['big'] as String).length, 3000);
    });

    test('another home is turned away', () async {
      final (m, h) = messagePipe();
      final hubF = SyncSession.accept(
        h,
        hubId,
        homeKey: randomBytes(32),
        homeName: 'Van',
      );
      await expectLater(
        SyncSession.connect(m, memberId, randomBytes(32)),
        throwsA(isA<SyncRefused>()),
      );
      expect(await hubF, isNull);
    });
  });
}

bool _contains(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
