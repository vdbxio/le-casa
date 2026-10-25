// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Ported from aiobmsble (https://github.com/patman15/aiobmsble),
// Copyright patman15 and contributors, Apache-2.0. See NOTICE.md.
//
// AG Automotive "AG Power Lithium": an E&J BMS behind another service.

import '../base_bms.dart';
import '../spec.dart';
import 'ej.dart';

class AgBms extends EjBms {
  static final spec = BmsSpec(
    module: 'ag_bms',
    info: const {'manufacturer': 'AG Automotive', 'model': 'AG Power Lithium'},
    matchers: const [
      MatcherPattern(localName: 'AG???L*', manufacturerId: 21320),
    ],
    create: AgBms.new,
  );

  AgBms(super.device, [super.config]);

  @override
  BmsInfo get info => spec.info;
  @override
  List<String> get uuidServices => ['00008000-0000-1000-8000-57616c6b697a'];
  @override
  String get uuidRx => '00008002-0000-1000-8000-57616c6b697a';
  @override
  String get uuidTx => '00008001-0000-1000-8000-57616c6b697a';
}
