// Loads League Spartan and the clock faces from the app's assets and Roboto plus Material icons
// from the Flutter SDK, so rendered previews look like the tablet.
import 'dart:io';

import 'package:flutter/services.dart';

Future<void> loadTestFonts() async {
  Future<void> load(String family, List<Future<ByteData>> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      l.addFont(f);
    }
    await l.load();
  }

  await load('LeagueSpartan', [
    for (final w in ['Regular', 'SemiBold', 'Bold'])
      rootBundle.load('assets/fonts/LeagueSpartan-$w.ttf'),
  ]);
  await load('JetBrainsMono', [
    rootBundle.load('assets/fonts/JetBrainsMono-Variable.ttf'),
  ]);
  await load('DMSerifDisplay', [
    rootBundle.load('assets/fonts/DMSerifDisplay-Regular.ttf'),
  ]);
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<ByteData> file(String name) async =>
      ByteData.sublistView(await File('$dir/$name').readAsBytes());
  if (!File('$dir/Roboto-Regular.ttf').existsSync()) return;
  await load('Roboto', [
    file('Roboto-Regular.ttf'),
    file('Roboto-Medium.ttf'),
    file('Roboto-Bold.ttf'),
  ]);
  await load('MaterialIcons', [file('MaterialIcons-Regular.otf')]);
}
