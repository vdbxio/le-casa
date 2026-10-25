// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception
//
// Every BMS driver ported from aiobmsble, and lookup by advertisement.

import '../decoders/raw_advertisement.dart';
import 'drivers/abc.dart';
import 'drivers/ag.dart';
import 'drivers/allpowers.dart';
import 'drivers/ant.dart';
import 'drivers/ant_leg.dart';
import 'drivers/braunpwr.dart';
import 'drivers/buknuwo.dart';
import 'drivers/c4s.dart';
import 'drivers/cbtpwr.dart';
import 'drivers/cbtpwr_vb.dart';
import 'drivers/daly.dart';
import 'drivers/daren.dart';
import 'drivers/dometic.dart';
import 'drivers/dpwrcore.dart';
import 'drivers/ecoworthy.dart';
import 'drivers/eg4.dart';
import 'drivers/ej.dart';
import 'drivers/eleksol.dart';
import 'drivers/jbd.dart';
import 'drivers/pwrboozt.dart';
import 'drivers/vatrer.dart';
import 'spec.dart';

export 'spec.dart';

final List<BmsSpec> bmsSpecs = [
  AbcBms.spec,
  AgBms.spec,
  AllpowersBms.spec,
  AntBms.spec,
  AntLegBms.spec,
  BraunpwrBms.spec,
  BuknuwoBms.spec,
  C4sBms.spec,
  CbtpwrBms.spec,
  CbtpwrVbBms.spec,
  DalyBms.spec,
  DarenBms.spec,
  DometicBms.spec,
  DpwrcoreBms.spec,
  EcoworthyBms.spec,
  Eg4Bms.spec,
  EjBms.spec,
  EleksolBms.spec,
  JbdBms.spec,
  PwrbooztBms.spec,
  VatrerBms.spec,
];

/// The BMS type an advertisement belongs to, or null.
BmsSpec? bmsSpecFor(RawAdvertisement adv) {
  for (final s in bmsSpecs) {
    if (s.supports(adv)) return s;
  }
  return null;
}

BmsSpec? bmsSpecByModule(String module) {
  for (final s in bmsSpecs) {
    if (s.module == module) return s;
  }
  return null;
}
