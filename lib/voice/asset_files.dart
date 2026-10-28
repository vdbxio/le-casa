// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// The path of a bundled voice model as a plain file, copied out of the
/// app the first time. The models are pinned (tool/fetch_voice.sh); a new
/// one needs a new file name. The engines
/// read files, and reading one into native memory skips the copies a
/// bundle load makes: on a 2 GB tablet those copies were enough for
/// Android to kill the app.
Future<String> voiceFile(String asset) async {
  final name = asset.replaceFirst('assets/voice/', '');
  final out = File(
    '${(await getApplicationSupportDirectory()).path}/voice/$name',
  );
  // Written whole and renamed, so a file that exists is complete; loading
  // the asset just to compare would cost the memory this saves.
  if (!await out.exists()) {
    final data = await rootBundle.load(asset);
    await out.parent.create(recursive: true);
    final tmp = File('${out.path}.part');
    await tmp.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    await tmp.rename(out.path);
  }
  return out.path;
}
