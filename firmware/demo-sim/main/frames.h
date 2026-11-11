// Le'Casa demo simulator - advertisement frame builders.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure C, no ESP-IDF types, so the same code builds on a laptop for the
// vector test (host/) that runs every frame through Le'Casa's own Dart
// decoders.

#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#define ADV_MAX 31

// AES-128 single block encrypt. Provided by aes_idf.c on the ESP32
// (mbedTLS) and by host/aes_host.c on a laptop (OpenSSL).
void aes128_encrypt_block(const uint8_t key[16], const uint8_t in[16],
                          uint8_t out[16]);

// Victron Instant Readout record types (victron-ble names).
enum {
    VICTRON_SOLAR_CHARGER = 0x01,
    VICTRON_BATTERY_MONITOR = 0x02,
    VICTRON_INVERTER = 0x03,
    VICTRON_VEBUS = 0x0C,
};

// Victron operation modes used by the simulator.
enum {
    VMODE_OFF = 0,
    VMODE_FAULT = 2,
    VMODE_BULK = 3,
    VMODE_ABSORPTION = 4,
    VMODE_FLOAT = 5,
    VMODE_INVERTING = 9,
};

typedef struct {
    uint8_t state;         // VMODE_*
    uint8_t error;         // 0 = none
    float battery_v;       // V
    float battery_a;       // A, charging current
    float yield_today_wh;  // Wh (sent in 10 Wh steps)
    float solar_w;         // W
    float load_a;          // A, or < 0 for "not available"
} solar_reading_t;

typedef struct {
    float soc;             // %
    float voltage;         // V
    float current;         // A, + charging, - discharging
    float consumed_ah;     // Ah used since full (positive number)
    int time_to_go_min;    // minutes, < 0 = not available (charging)
    uint16_t alarm;        // 0 = none
    float temperature_c;   // battery temperature (aux input in temp mode)
} shunt_reading_t;

typedef struct {
    uint8_t state;
    uint16_t alarm;
    float battery_v;
    float ac_va;           // apparent power out, VA
    float ac_v;            // output voltage
    float ac_a;            // output current
} inverter_reading_t;

typedef struct {
    uint8_t state;
    uint8_t error;
    float battery_a;       // + charging, - discharging
    float battery_v;
    uint8_t ac_in_state;   // 0 AC in 1, 1 AC in 2, 2 not connected
    int ac_in_w;
    int ac_out_w;
    int battery_temp_c;
    int soc;               // %, < 0 = not available
} vebus_reading_t;

// Plain record payloads (before encryption). Return the length.
size_t victron_solar_record(uint8_t *out, const solar_reading_t *r);
size_t victron_shunt_record(uint8_t *out, const shunt_reading_t *r);
size_t victron_inverter_record(uint8_t *out, const inverter_reading_t *r);
size_t victron_vebus_record(uint8_t *out, const vebus_reading_t *r);

// Manufacturer data value (company id first, as it sits in the AD
// structure after the 0xFF type byte): E1 02 10 02 <model> <record>
// <iv> <key0> <encrypted record>. Returns its length.
size_t victron_mfr_data(uint8_t *out, const uint8_t key[16], uint16_t model,
                        uint8_t record, uint16_t iv, const uint8_t *plain,
                        size_t plain_len);

typedef struct {
    float temperature_c;
    float humidity;        // %, < 0 = leave out
    int battery;           // %, < 0 = leave out
    uint8_t packet_id;
} bthome_reading_t;

// BTHome v2 service data value (UUID first): D2 FC 40 <objects>.
size_t bthome_service_data(uint8_t *out, const bthome_reading_t *r);

// Whole advertisement / scan response builders. Return the length or 0
// when it would not fit.
size_t adv_with_mfr(uint8_t *out, const uint8_t *mfr, size_t mfr_len);
size_t adv_with_service_data(uint8_t *out, const uint8_t *sd, size_t sd_len,
                             const char *name);
size_t scan_rsp_name(uint8_t *out, const char *name);
