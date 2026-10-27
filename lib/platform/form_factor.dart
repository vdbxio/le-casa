// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'dart:ui';

/// True for a phone-sized screen: the shorter side under 600 logical
/// pixels, Material's line between phones and tablets. The shorter side
/// does not change when the screen rotates.
bool isPhoneSize(Size size) => size.shortestSide < 600;
