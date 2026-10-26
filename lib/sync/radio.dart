// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'framing.dart';

/// The one Le'Casa GATT service, shared by screen sync now and the
/// phone companion and Le' devices later. "LeCasa" in the first bytes.
const syncServiceUuid = '4c654361-7361-4c65-8000-000000000000';

/// Read: what this screen is (plain JSON, no secrets).
const syncInfoUuid = '4c654361-7361-4c65-8000-000000000001';

/// Write: member to hub chunks.
const syncRxUuid = '4c654361-7361-4c65-8000-000000000002';

/// Notify: hub to member chunks.
const syncTxUuid = '4c654361-7361-4c65-8000-000000000003';

/// Manufacturer id for the home tag in an Android hub's advert. 0xFFFF is
/// the id the Bluetooth SIG keeps for testing; fine until Le'Casa has one.
const syncCompanyId = 0xFFFF;

/// Prefix of the advertised name on an iOS hub, which cannot send
/// manufacturer data: "LeCasa 1a2b3c4d".
const syncNamePrefix = 'LeCasa ';

/// A hub heard on the air.
class HubSighting {
  /// Scanner id, to connect.
  final String id;

  /// Home tag from the advert, when it carried one.
  final String? tag;
  final int rssi;
  final DateTime seen;

  const HubSighting(this.id, this.tag, this.rssi, this.seen);
}

/// What screen sync needs from Bluetooth, so the service can be tested
/// with links in memory.
abstract interface class SyncRadio {
  /// Starts the GATT server and advertises [tag].
  Future<void> startHub(String tag);

  Future<void> stopHub();

  /// New member links while the hub is up.
  Stream<MessageLink> get incoming;

  /// Le'Casa hubs nearby, as the scanner hears them.
  Stream<HubSighting> get sightings;

  /// Connects to a hub. Throws when it cannot.
  Future<MessageLink> connect(HubSighting hub);
}
