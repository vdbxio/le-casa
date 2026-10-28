// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

/// FFI bindings to Cactus's voice engine (third_party/needle/needle.h),
/// built into the app by hook/build.dart. The engine is process-global and
/// not thread-safe: only [VoiceEngine]'s worker isolate calls these.
// ignore_for_file: non_constant_identifier_names
@DefaultAsset('package:lecasa/voice/needle.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

const needleText = 1;
const needleSpeech = 2;

@Native<Int Function(Pointer<Uint8>, UnsignedLongLong)>()
external int needle_load(Pointer<Uint8> cact, int n);

@Native<Int Function()>()
external int needle_models();

@Native<Pointer<Utf8> Function()>()
external Pointer<Utf8> needle_last_error();

@Native<Int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)>()
external int needle_init(
  Pointer<Utf8> systemPrompt,
  Pointer<Utf8> toolsJson,
  Pointer<Utf8> toolIndexPath,
);

@Native<
  Int Function(Pointer<Utf8>, Pointer<Float>, Int, Int, Pointer<Utf8>, Int)
>()
external int needle_complete(
  Pointer<Utf8> input,
  Pointer<Float> pcm,
  int samples,
  int maxNewTokens,
  Pointer<Utf8> out,
  int outCapacity,
);

@Native<Void Function(Pointer<Utf8>, Pointer<Utf8>, Int)>()
external void needle_set_audio(
  Pointer<Utf8> language,
  Pointer<Utf8> keywords,
  int wordTimestamps,
);

@Native<Void Function()>()
external void needle_reset();

@Native<
  Int Function(
    Pointer<Float>,
    Int,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Int,
    Pointer<Utf8>,
    Int,
  )
>()
external int needle_transcribe(
  Pointer<Float> pcm,
  int samples,
  Pointer<Utf8> language,
  Pointer<Utf8> keywords,
  int wordTimestamps,
  Pointer<Utf8> out,
  int outCapacity,
);
