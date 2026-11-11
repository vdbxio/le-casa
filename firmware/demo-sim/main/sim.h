// Le'Casa demo simulator - the pretend bus electrical system.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// One small model drives every simulated device, so the numbers agree
// with each other the way a real system's do: the shunt's current is the
// chargers' output minus the loads, the MPPTs see the shunt's voltage,
// and the MultiPlus draws what the AC loads need.

#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "frames.h"

typedef enum {
    SCENE_AUTO = 0,   // follow the demo clock, passing clouds, random loads
    SCENE_SUNNY,      // clear noon, light loads: batteries filling
    SCENE_CLOUDY,     // heavy cloud, solar comes and goes
    SCENE_NIGHT,      // no sun, evening loads: batteries draining
    SCENE_BIG_LOAD,   // induction hob / kettle on the inverter
    SCENE_SHORE,      // plugged in at a campground: MultiPlus charging
    SCENE_COUNT,
} scene_t;

const char *scene_name(scene_t s);

typedef struct {
    // Settings (sim_defaults fills them; change before sim_init).
    float day_minutes;      // real minutes per demo day
    float start_hour;       // demo clock at boot
    float capacity_ah;      // house battery
    int cells;              // LiFePO4 cells in series (8 = 24 V)
    float roof_w;           // panel watts on charger 1
    float roof_max_a;       // charger 1 limit
    float portable_w;       // panel watts on charger 2
    float portable_max_a;   // charger 2 limit
    float ac_volts;         // 120 or 230
    uint32_t seed;

    // State.
    scene_t scene;
    float hour;             // demo clock, 0..24
    float soc;              // %
    float cloud;            // 0..1 multiplier on sunshine
    float cloud_target;
    float dc_load_a;
    float ac_load_w;
    float ac_event_w;       // kettle, microwave, ...
    float ac_event_left_s;  // real seconds left on the current event
    float next_event_s;
    bool shore;             // AC input connected
    bool fridge_on;
    float fridge_c;
    float cabin_c;
    float cabin_rh;
    float roof_yield_wh;
    float portable_yield_wh;
    float battery_v;
    float battery_a;        // net, + charging
    uint32_t rng;
    uint8_t packet_id;
} sim_t;

void sim_defaults(sim_t *s);
void sim_init(sim_t *s);
void sim_set_scene(sim_t *s, scene_t scene);
void sim_kettle(sim_t *s);

// Advance by dt real seconds.
void sim_step(sim_t *s, float dt);

// Readings as each device would report them right now.
void sim_roof(const sim_t *s, solar_reading_t *r);
void sim_portable(const sim_t *s, solar_reading_t *r);
void sim_shunt(const sim_t *s, shunt_reading_t *r);
void sim_multiplus(const sim_t *s, vebus_reading_t *r);
void sim_inverter(const sim_t *s, inverter_reading_t *r);
void sim_cabin(sim_t *s, bthome_reading_t *r);
void sim_fridge(sim_t *s, bthome_reading_t *r);
