// Le'Casa demo simulator - which devices to pretend to be.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Edit this table to change the line-up. Each entry gets its own random
// static address (derived from the board's MAC and the slot number), so
// Le'Casa sees separate devices that keep their identity across reboots.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "sim.h"

typedef enum {
    DEV_ROOF_MPPT,
    DEV_PORTABLE_MPPT,
    DEV_SHUNT,
    DEV_MULTIPLUS,
    DEV_INVERTER,
    DEV_CABIN,
    DEV_FRIDGE,
} dev_kind_t;

typedef struct {
    dev_kind_t kind;
    const char *name;     // shown as the card title in Le'Casa
    uint16_t model;       // Victron product id (victron_models.dart)
    uint8_t key[16];      // Victron Instant Readout key; unused for BTHome
    uint16_t iv;          // Victron frame counter, bumped on every frame
} demo_device_t;

extern demo_device_t demo_devices[];
extern const size_t demo_device_count;

// Builds slot i's advertisement and scan response from the model.
// Returns false when the slot has nothing to send.
bool demo_device_frames(demo_device_t *d, sim_t *s, uint8_t *adv,
                        size_t *adv_len, uint8_t *rsp, size_t *rsp_len);
