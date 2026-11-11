// Le'Casa demo simulator - the pretend bus electrical system.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

#include "sim.h"

#include <math.h>
#include <stddef.h>

#define PI_F 3.14159265f

static const char *const scene_names[SCENE_COUNT] = {
    "auto", "sunny", "cloudy", "night", "big-load", "shore",
};

const char *scene_name(scene_t s)
{
    return s < SCENE_COUNT ? scene_names[s] : "?";
}

static float clampf(float v, float lo, float hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

// xorshift32: small, and the same on the ESP32 and the laptop test.
static float rnd(sim_t *s)
{
    uint32_t x = s->rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    s->rng = x;
    return (x >> 8) / 16777216.0f;  // 0..1
}

static float noise(sim_t *s, float amp) { return (rnd(s) * 2 - 1) * amp; }

static float cell_ocv(float soc);

void sim_defaults(sim_t *s)
{
    *s = (sim_t){
        .day_minutes = 24,
        .start_hour = 9.5f,
        .capacity_ah = 300,
        .cells = 8,
        .roof_w = 800,
        .roof_max_a = 50,
        .portable_w = 400,
        .portable_max_a = 30,
        .ac_volts = 120,
        .seed = 0x1e5ca5a,
    };
}

void sim_init(sim_t *s)
{
    s->rng = s->seed ? s->seed : 1;
    s->scene = SCENE_AUTO;
    s->hour = s->start_hour;
    s->soc = 68;
    s->cloud = s->cloud_target = 0.9f;
    s->dc_load_a = 2.5f;
    s->ac_load_w = 45;
    s->next_event_s = 20;
    s->fridge_c = 4;
    s->cabin_c = 20;
    s->cabin_rh = 50;
    s->battery_v = s->cells * cell_ocv(s->soc);
}

void sim_set_scene(sim_t *s, scene_t scene)
{
    s->scene = scene;
    s->shore = scene == SCENE_SHORE;
    if (scene == SCENE_BIG_LOAD) {
        s->ac_event_w = 1800;
        s->ac_event_left_s = 1e9f;  // until the scene changes
    } else if (s->ac_event_left_s > 1e8f) {
        s->ac_event_w = 0;
        s->ac_event_left_s = 0;
    }
}

void sim_kettle(sim_t *s)
{
    s->ac_event_w = 1500;
    s->ac_event_left_s = 20;
}

// Sunshine 0..1 from the clock: up at 6, down at 20, a little peaky.
static float sun_at(float hour)
{
    if (hour <= 6 || hour >= 20) return 0;
    return powf(sinf(PI_F * (hour - 6) / 14), 1.3f);
}

static float sunshine(const sim_t *s)
{
    switch (s->scene) {
    case SCENE_SUNNY: return 0.97f;
    case SCENE_NIGHT: return 0;
    case SCENE_CLOUDY: return sun_at(12.5f) * s->cloud;
    default: return sun_at(s->hour) * s->cloud;
    }
}

// Resting LiFePO4 cell voltage for a state of charge.
static float cell_ocv(float soc)
{
    static const float pts[][2] = {
        {0, 2.90f},  {5, 3.10f},  {10, 3.20f}, {20, 3.25f}, {40, 3.29f},
        {60, 3.31f}, {80, 3.33f}, {90, 3.35f}, {97, 3.40f}, {100, 3.45f},
    };
    for (size_t i = 1; i < sizeof pts / sizeof pts[0]; i++) {
        if (soc <= pts[i][0]) {
            float t = (soc - pts[i - 1][0]) / (pts[i][0] - pts[i - 1][0]);
            return pts[i - 1][1] + t * (pts[i][1] - pts[i - 1][1]);
        }
    }
    return pts[9][1];
}

// What each charger is doing, from its panels and the battery.
typedef struct {
    float w, a;
    uint8_t mode;
} charger_t;

static charger_t charger(const sim_t *s, float panel_w, float max_a,
                         float jitter)
{
    charger_t c = {0, 0, VMODE_OFF};
    float w = panel_w * sunshine(s) * (0.94f + jitter);
    if (w < 3) return c;
    float v = s->battery_v;
    float a = w * 0.97f / v;
    if (a > max_a) {
        a = max_a;
        w = a * v / 0.97f;
    }
    c.mode = VMODE_BULK;
    // Full battery: absorption tapers the current, float holds it.
    if (s->soc >= 99.5f) {
        c.mode = VMODE_FLOAT;
        a = fminf(a, 1.5f);
    } else if (s->soc >= 92) {
        c.mode = VMODE_ABSORPTION;
        a = fminf(a, max_a * (100 - s->soc) / 10);
    }
    c.a = a;
    c.w = a * v / 0.97f;
    return c;
}

// Shore charger current: 40 A bulk, tapering through absorption.
static float charge_a(const sim_t *s)
{
    if (!s->shore) return 0;
    if (s->soc >= 99.5f) return 1;
    if (s->soc >= 92) return fmaxf(1, 40 * (100 - s->soc) / 8);
    return 40;
}

// DC draw of the AC side through the inverter (positive = from battery).
static float inverter_dc_a(const sim_t *s)
{
    if (s->shore) return 0;  // passed through from shore
    return (s->ac_load_w + s->ac_event_w) / 0.92f / s->battery_v;
}

void sim_step(sim_t *s, float dt)
{
    if (dt <= 0) return;
    float demo_h = dt * 24 / (s->day_minutes * 60);  // demo hours elapsed
    float prev = s->hour;
    s->hour += demo_h;
    if (s->hour >= 24) s->hour -= 24;
    if (s->hour < prev) s->roof_yield_wh = s->portable_yield_wh = 0;

    // Clouds drift toward a target that changes every so often.
    float clear = s->scene == SCENE_CLOUDY ? 0.35f : 0.85f;
    if (rnd(s) < dt / 8) s->cloud_target = clampf(clear + noise(s, 0.3f), 0.1f, 1);
    if (s->scene == SCENE_SUNNY) s->cloud_target = 1;
    s->cloud += (s->cloud_target - s->cloud) * clampf(dt / 3, 0, 1);

    // DC loads: lights in the evening, the water pump now and then.
    bool evening = s->scene == SCENE_NIGHT || s->hour >= 18 || s->hour < 7;
    float dc = 1.2f + (evening ? 2.5f : 0.4f);
    if (rnd(s) < dt / 30) dc += 3;  // pump blip, smoothed below
    s->dc_load_a += (dc - s->dc_load_a) * clampf(dt / 2, 0, 1);

    // Fridge compressor cycles on its own thermostat.
    s->fridge_c += (s->fridge_on ? -0.5f : 0.12f) * dt / 10 + noise(s, 0.01f);
    if (s->fridge_c > 5) s->fridge_on = true;
    if (s->fridge_c < 2.5f) s->fridge_on = false;

    // AC loads: a laptop and router base, plus the odd kettle or microwave.
    s->ac_load_w += (40 + (evening ? 60 : 15) + noise(s, 5) - s->ac_load_w) *
                    clampf(dt / 4, 0, 1);
    if (s->ac_event_left_s > 0) {
        s->ac_event_left_s -= dt;
        if (s->ac_event_left_s <= 0) s->ac_event_w = 0;
    } else if (s->scene == SCENE_AUTO && s->soc > 35) {
        s->next_event_s -= dt;
        if (s->next_event_s <= 0) {
            static const float watts[] = {1500, 1100, 700, 350};
            s->ac_event_w = watts[(int)(rnd(s) * 4) & 3];
            s->ac_event_left_s = 10 + rnd(s) * 20;
            s->next_event_s = 45 + rnd(s) * 60;
        }
    }

    // Auto mode plugs into shore power when the battery gets low, and
    // unplugs once it has some charge back, so a demo left running all
    // day never goes flat.
    if (s->scene == SCENE_AUTO) {
        if (s->soc < 25) s->shore = true;
        if (s->shore && s->soc > 60) s->shore = false;
    }

    // Net battery current, then charge in demo time.
    charger_t roof = charger(s, s->roof_w, s->roof_max_a, 0);
    charger_t port = charger(s, s->portable_w, s->portable_max_a, -0.03f);
    float fridge_a = s->fridge_on ? 2.2f : 0;
    float net = roof.a + port.a + charge_a(s) - s->dc_load_a - fridge_a -
                inverter_dc_a(s);
    // A full battery takes no more: the chargers just carry the loads.
    if (s->soc >= 99.5f && net > 0.3f) net = 0.3f;
    s->soc = clampf(s->soc + net * demo_h / s->capacity_ah * 100, 3, 100);
    s->roof_yield_wh += roof.w * demo_h;
    s->portable_yield_wh += port.w * demo_h;

    // Terminal voltage: resting voltage plus a little internal resistance,
    // pulled up to absorption / float while charging a full battery.
    float v = s->cells * cell_ocv(s->soc) + net * 0.0025f * s->cells / 4;
    if (net > 0 && s->soc >= 92) v = fmaxf(v, s->cells * 3.5f);
    if (roof.mode == VMODE_FLOAT) v = s->cells * 3.375f;
    s->battery_v += (v - s->battery_v) * clampf(dt / 2, 0, 1);
    s->battery_a = net;

    // Cabin follows the sun a little.
    float cabin = 16 + 9 * sunshine(s) + noise(s, 0.05f);
    s->cabin_c += (cabin - s->cabin_c) * clampf(dt / 60, 0, 1);
    s->cabin_rh = clampf(62 - (s->cabin_c - 16) * 1.6f + noise(s, 0.4f), 25, 90);
}

static void fill_solar(const sim_t *s, solar_reading_t *r, float panel_w,
                       float max_a, float jitter, float yield, float vofs)
{
    charger_t c = charger(s, panel_w, max_a, jitter);
    *r = (solar_reading_t){
        .state = c.mode,
        .battery_v = s->battery_v + vofs,
        .battery_a = c.a,
        .yield_today_wh = yield,
        .solar_w = c.w,
        .load_a = -1,
    };
}

void sim_roof(const sim_t *s, solar_reading_t *r)
{
    fill_solar(s, r, s->roof_w, s->roof_max_a, 0, s->roof_yield_wh, 0.04f);
}

void sim_portable(const sim_t *s, solar_reading_t *r)
{
    fill_solar(s, r, s->portable_w, s->portable_max_a, -0.03f,
               s->portable_yield_wh, 0.02f);
}

void sim_shunt(const sim_t *s, shunt_reading_t *r)
{
    float used = (100 - s->soc) / 100 * s->capacity_ah;
    int ttg = -1;
    if (s->battery_a < -0.3f) {
        // Real-time minutes to 0 %, like the shunt works it out.
        ttg = (int)(s->soc / 100 * s->capacity_ah / -s->battery_a * 60);
        if (ttg > 0xFFFE) ttg = 0xFFFE;
    }
    *r = (shunt_reading_t){
        .soc = s->soc,
        .voltage = s->battery_v,
        .current = s->battery_a,
        .consumed_ah = used,
        .time_to_go_min = ttg,
        .temperature_c = 14 + s->cabin_c * 0.3f,
    };
}

void sim_multiplus(const sim_t *s, vebus_reading_t *r)
{
    int out_w = (int)(s->ac_load_w + s->ac_event_w);
    float bat_a = s->shore ? charge_a(s) : -inverter_dc_a(s);
    uint8_t state = VMODE_INVERTING;
    if (s->shore)
        state = s->soc >= 99.5f ? VMODE_FLOAT
                : s->soc >= 92  ? VMODE_ABSORPTION
                                : VMODE_BULK;
    *r = (vebus_reading_t){
        .state = state,
        .battery_a = bat_a,
        .battery_v = s->battery_v,
        .ac_in_state = s->shore ? 0 : 2,
        .ac_in_w = s->shore ? (int)(out_w + bat_a * s->battery_v / 0.92f) : 0,
        .ac_out_w = out_w,
        .battery_temp_c = (int)lroundf(14 + s->cabin_c * 0.3f),
        .soc = (int)lroundf(s->soc),
    };
}

void sim_inverter(const sim_t *s, inverter_reading_t *r)
{
    float w = s->ac_load_w + s->ac_event_w;
    float va = w / 0.95f;
    *r = (inverter_reading_t){
        .state = VMODE_INVERTING,
        .battery_v = s->battery_v,
        .ac_va = va,
        .ac_v = s->ac_volts + (s->ac_volts > 200 ? 0.4f : 0.2f),
        .ac_a = va / s->ac_volts,
    };
}

void sim_cabin(sim_t *s, bthome_reading_t *r)
{
    *r = (bthome_reading_t){
        .temperature_c = s->cabin_c,
        .humidity = s->cabin_rh,
        .battery = 87,
        .packet_id = ++s->packet_id,
    };
}

void sim_fridge(sim_t *s, bthome_reading_t *r)
{
    *r = (bthome_reading_t){
        .temperature_c = s->fridge_c,
        .humidity = -1,
        .battery = 64,
        .packet_id = ++s->packet_id,
    };
}
