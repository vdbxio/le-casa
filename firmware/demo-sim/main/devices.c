// Le'Casa demo simulator - which devices to pretend to be.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

#include "devices.h"

// These keys are public on purpose: they are printed in the README and
// on the serial console so a demo screen can be set up in a minute.
// Never reuse them on real equipment.
demo_device_t demo_devices[] = {
    {
        .kind = DEV_ROOF_MPPT,
        .name = "Roof Solar",
        .model = 0xA057,  // SmartSolar MPPT 100/50
        .key = {0x7a, 0xc2, 0x3c, 0xbd, 0x97, 0x01, 0xa2, 0x60,
                0x65, 0x11, 0xa8, 0xc3, 0x5f, 0xf7, 0x12, 0x31},
    },
    {
        .kind = DEV_PORTABLE_MPPT,
        .name = "Portable Solar",
        .model = 0xA056,  // SmartSolar MPPT 100/30
        .key = {0x15, 0xcd, 0x25, 0x85, 0x8a, 0x29, 0x3c, 0x2a,
                0x4e, 0x22, 0xe4, 0x44, 0x99, 0x32, 0xaf, 0x58},
    },
    {
        .kind = DEV_SHUNT,
        .name = "House Battery",
        .model = 0xA389,  // SmartShunt 500A/50mV
        .key = {0xd9, 0xdb, 0x30, 0xa2, 0xd6, 0xc1, 0xb4, 0xd6,
                0x18, 0x94, 0xfd, 0x7f, 0x37, 0xd4, 0x47, 0xb2},
    },
    {
        .kind = DEV_MULTIPLUS,
        .name = "MultiPlus",
        .model = 0x2711,  // MultiPlus-II 24/3000/70-50 120V
        .key = {0x2e, 0x34, 0xb2, 0x64, 0x03, 0x9a, 0xa3, 0x56,
                0x5d, 0x7e, 0xee, 0x05, 0x55, 0x0e, 0x3c, 0xef},
    },
    {.kind = DEV_CABIN, .name = "Cabin"},
    {.kind = DEV_FRIDGE, .name = "Fridge"},
    // A stand-alone Phoenix inverter instead of (or as well as) the
    // MultiPlus:
    // {
    //     .kind = DEV_INVERTER,
    //     .name = "Inverter",
    //     .model = 0xA27A,  // Phoenix Inverter 24V 1200VA 120V
    //     .key = {0x4b, 0x1f, 0x80, 0x22, 0x9e, 0x6d, 0x31, 0xc4,
    //             0x07, 0xaa, 0x5e, 0x13, 0x68, 0xf0, 0xd2, 0x95},
    // },
};

const size_t demo_device_count = sizeof demo_devices / sizeof demo_devices[0];

static bool victron(demo_device_t *d, uint8_t record, const uint8_t *plain,
                    size_t plain_len, uint8_t *adv, size_t *adv_len,
                    uint8_t *rsp, size_t *rsp_len)
{
    uint8_t mfr[ADV_MAX];
    size_t n = victron_mfr_data(mfr, d->key, d->model, record, d->iv++, plain,
                                plain_len);
    *adv_len = n ? adv_with_mfr(adv, mfr, n) : 0;
    // Victron puts the name in the scan response.
    *rsp_len = scan_rsp_name(rsp, d->name);
    return *adv_len > 0;
}

bool demo_device_frames(demo_device_t *d, sim_t *s, uint8_t *adv,
                        size_t *adv_len, uint8_t *rsp, size_t *rsp_len)
{
    uint8_t plain[16];
    size_t n;
    switch (d->kind) {
    case DEV_ROOF_MPPT:
    case DEV_PORTABLE_MPPT: {
        solar_reading_t r;
        if (d->kind == DEV_ROOF_MPPT) sim_roof(s, &r); else sim_portable(s, &r);
        n = victron_solar_record(plain, &r);
        return victron(d, VICTRON_SOLAR_CHARGER, plain, n, adv, adv_len, rsp,
                       rsp_len);
    }
    case DEV_SHUNT: {
        shunt_reading_t r;
        sim_shunt(s, &r);
        n = victron_shunt_record(plain, &r);
        return victron(d, VICTRON_BATTERY_MONITOR, plain, n, adv, adv_len, rsp,
                       rsp_len);
    }
    case DEV_MULTIPLUS: {
        vebus_reading_t r;
        sim_multiplus(s, &r);
        n = victron_vebus_record(plain, &r);
        return victron(d, VICTRON_VEBUS, plain, n, adv, adv_len, rsp, rsp_len);
    }
    case DEV_INVERTER: {
        inverter_reading_t r;
        sim_inverter(s, &r);
        n = victron_inverter_record(plain, &r);
        return victron(d, VICTRON_INVERTER, plain, n, adv, adv_len, rsp,
                       rsp_len);
    }
    case DEV_CABIN:
    case DEV_FRIDGE: {
        bthome_reading_t r;
        if (d->kind == DEV_CABIN) sim_cabin(s, &r); else sim_fridge(s, &r);
        uint8_t sd[ADV_MAX];
        n = bthome_service_data(sd, &r);
        *adv_len = adv_with_service_data(adv, sd, n, d->name);
        *rsp_len = 0;
        return *adv_len > 0;
    }
    }
    return false;
}
