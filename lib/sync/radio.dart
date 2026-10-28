// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'framing.dart';

/// The one Le'Casa GATT service, shared by screen sync now and the
/// phone companion and Le' devices later. "LeCasa" in the first bytes.
const syncServiceUuid = '4c654361-7361-4c65-8000-000000000000';

/// Read: what this screen is (plain JSON, no secrets).
const syncInfoUuid = '4c654361-7361-4c65-8000-000000000001';

/// Write: chunks from the screen that connected.
const syncRxUuid = '4c654361-7361-4c65-8000-000000000002';

/// Notify: chunks to the screen that connected.
const syncTxUuid = '4c654361-7361-4c65-8000-000000000003';

/// Manufacturer id for the home tag in an Android screen's advert. 0xFFFF
/// is the id the Bluetooth SIG keeps for testing; fine until Le'Casa has
/// one. The data starts with "LC" so other test gear is not mistaken for
/// a screen.
const syncCompanyId = 0xFFFF;
const syncMagic = [0x4C, 0x43];

/// Prefix of the advertised name on an iOS screen, which cannot send
/// manufacturer data: "LeCasa 1a2b3c4d.0f1e2d3c" (home tag, screen), with
/// a "+" on the end while the screen is adding new ones.
const syncNamePrefix = 'LeCasa ';

/// The first 8 hex digits of a screen id, which is what fits in an advert.
String shortScreen(String id) => id.length <= 8 ? id : id.substring(0, 8);

/// What a screen in a home puts on the air.
class PeerAdvert {
  final String tag;

  /// [shortScreen] of the screen's id.
  final String screen;

  /// Taking new screens right now.
  final bool adding;

  const PeerAdvert(this.tag, this.screen, {this.adding = false});
}

/// A Le'Casa screen heard on the air.
class PeerSighting {
  /// Scanner id, to connect.
  final String id;

  /// Home tag from the advert, when it carried one.
  final String? tag;

  /// [shortScreen] of the screen, when the advert carried it.
  final String? screen;
  final bool adding;
  final int rssi;
  final DateTime seen;

  /// An Android screen (its advert carries manufacturer data, which iOS
  /// cannot send).
  final bool android;

  const PeerSighting(
    this.id,
    this.tag,
    this.rssi,
    this.seen, {
    this.screen,
    this.adding = false,
    this.android = false,
  });
}

/// What screen sync needs from Bluetooth, so the service can be tested
/// with links in memory. Every screen in a home is both ends: it serves
/// links to the screens that connect to it, and connects to others.
abstract interface class SyncRadio {
  /// Starts the GATT server if needed and advertises [ad]. Called again
  /// when the advert changes.
  Future<void> startServer(PeerAdvert ad);

  Future<void> stopServer();

  /// Links from screens that connected to this one.
  Stream<MessageLink> get incoming;

  /// Le'Casa screens nearby, as the scanner hears them.
  Stream<PeerSighting> get sightings;

  /// Connects to a screen. Throws when it cannot.
  Future<MessageLink> connect(PeerSighting peer);
}
