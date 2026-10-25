// Le'Casa - Bluetooth-first home automation.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later WITH App-Store-Exception

import 'package:flutter/material.dart';

/// Icons a card's title can be given in card options, saved by name.
/// A fixed list rather than every Material icon keeps icon tree shaking
/// working and the picker short enough to scan.
const cardIcons = <String, IconData>{
  'sun': Icons.wb_sunny_outlined,
  'solar': Icons.solar_power_outlined,
  'bolt': Icons.bolt,
  'battery': Icons.battery_charging_full,
  'battery_full': Icons.battery_full,
  'plug': Icons.power_outlined,
  'outlet': Icons.electrical_services,
  'ev': Icons.ev_station_outlined,
  'car': Icons.directions_car_outlined,
  'van': Icons.airport_shuttle_outlined,
  'boat': Icons.sailing_outlined,
  'home': Icons.home_outlined,
  'cabin': Icons.cabin_outlined,
  'thermostat': Icons.thermostat,
  'heat': Icons.local_fire_department_outlined,
  'cold': Icons.ac_unit,
  'fan': Icons.air,
  'water': Icons.water_drop_outlined,
  'tank': Icons.propane_tank_outlined,
  'humidity': Icons.water_outlined,
  'fridge': Icons.kitchen_outlined,
  'light': Icons.lightbulb_outline,
  'lamp': Icons.light_outlined,
  'tv': Icons.tv,
  'speaker': Icons.speaker_outlined,
  'router': Icons.router_outlined,
  'sensor': Icons.sensors,
  'remote': Icons.settings_remote_outlined,
  'key': Icons.key_outlined,
  'lock': Icons.lock_outline,
  'door': Icons.door_front_door_outlined,
  'window': Icons.window_outlined,
  'bed': Icons.bed_outlined,
  'plant': Icons.yard_outlined,
  'pet': Icons.pets_outlined,
  'weather': Icons.cloud_outlined,
  'clock': Icons.schedule,
  'tablet': Icons.tablet_android,
  'phone': Icons.smartphone,
  'heart': Icons.favorite_outline,
  'star': Icons.star_outline,
};
