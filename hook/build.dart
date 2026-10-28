// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Links Cactus's prebuilt voice engine (third_party/needle) into a shared
/// library the app loads through FFI. The static libraries are fetched by
/// tool/fetch_voice.sh; without one for the target the app builds as
/// before and voice says it is not installed.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final folder = switch ((code.targetOS, code.targetArchitecture)) {
      (OS.android, Architecture.arm) => 'android-armv7',
      (OS.android, Architecture.arm64) => 'android-arm64',
      (OS.iOS, Architecture.arm64) =>
        code.iOS.targetSdk == IOSSdk.iPhoneSimulator
            ? 'ios-sim-arm64'
            : 'ios-arm64',
      (OS.macOS, Architecture.arm64) => 'macos-arm64',
      _ => null,
    };
    if (folder == null) return;
    final root = input.packageRoot.resolve('third_party/needle/');
    final archive = root.resolve('$folder/libneedle.a');
    if (!File.fromUri(archive).existsSync()) return;
    output.dependencies.add(archive);
    final android = code.targetOS == OS.android;
    await CBuilder.library(
      name: 'needle',
      assetName: 'voice/needle.dart',
      sources: ['third_party/needle/keep.cc'],
      language: Language.cpp,
      cppLinkStdLib: android ? 'c++_static' : null,
      libraries: android ? ['m', 'log'] : [],
      flags: android
          ? [
              '-Wl,--whole-archive,${archive.toFilePath()},--no-whole-archive',
              // Export only the engine's C API, not the libc++ inside it.
              '-Wl,--version-script=${root.resolve('needle.map').toFilePath()}',
              '-Wl,--gc-sections',
            ]
          : ['-Wl,-force_load,${archive.toFilePath()}'],
    ).run(input: input, output: output);
  });
}
