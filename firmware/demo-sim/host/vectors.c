// Runs the simulator on a laptop through every scene and writes each
// device's frames, plus the values they should decode to, as JSON for
// test/demo_sim_test.dart. See host/gen_vectors.sh.
// SPDX-License-Identifier: GPL-3.0-or-later

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "../main/devices.h"

static void hexs(const char *k, const uint8_t *b, size_t n)
{
    printf("\"%s\":\"", k);
    for (size_t i = 0; i < n; i++) printf("%02x", b[i]);
    printf("\"");
}

static const char *mode(uint8_t m)
{
    switch (m) {
    case VMODE_OFF: return "Off";
    case VMODE_BULK: return "Bulk";
    case VMODE_ABSORPTION: return "Absorption";
    case VMODE_FLOAT: return "Float";
    case VMODE_INVERTING: return "Inverting";
    default: return "?";
    }
}

// Expected readings, worked out from the same structs the frames were
// built from (before the wire rounding, so the test checks rounding too).
static void expect(demo_device_t *d, sim_t *s)
{
    printf("\"expect\":{");
    switch (d->kind) {
    case DEV_ROOF_MPPT:
    case DEV_PORTABLE_MPPT: {
        solar_reading_t r;
        if (d->kind == DEV_ROOF_MPPT) sim_roof(s, &r); else sim_portable(s, &r);
        printf("\"charge state\":\"%s\",\"battery voltage\":%.4f,"
               "\"battery current\":%.4f,\"yield today\":%.2f,"
               "\"solar power\":%.2f,\"load current\":null",
               mode(r.state), r.battery_v, r.battery_a, r.yield_today_wh,
               r.solar_w);
        break;
    }
    case DEV_SHUNT: {
        shunt_reading_t r;
        sim_shunt(s, &r);
        printf("\"state of charge\":%.4f,\"voltage\":%.4f,\"current\":%.4f,"
               "\"consumed\":%.4f,\"temperature\":%.4f,\"alarm\":\"No alarm\"",
               r.soc, r.voltage, r.current, -r.consumed_ah, r.temperature_c);
        if (r.time_to_go_min < 0) printf(",\"time to go\":null");
        else printf(",\"time to go\":%d", r.time_to_go_min);
        break;
    }
    case DEV_MULTIPLUS: {
        vebus_reading_t r;
        sim_multiplus(s, &r);
        printf("\"state\":\"%s\",\"ac out power\":%d,\"battery voltage\":%.4f,"
               "\"battery current\":%.4f,\"ac in power\":%d,"
               "\"state of charge\":%d,\"battery temperature\":%d,"
               "\"ac input\":\"%s\"",
               mode(r.state), r.ac_out_w, r.battery_v, r.battery_a, r.ac_in_w,
               r.soc, r.battery_temp_c,
               r.ac_in_state == 2 ? "Not connected" : "AC in 1");
        break;
    }
    case DEV_INVERTER: {
        inverter_reading_t r;
        sim_inverter(s, &r);
        printf("\"state\":\"%s\",\"ac power\":%.2f,\"battery voltage\":%.4f,"
               "\"ac voltage\":%.4f,\"ac current\":%.4f,\"alarm\":\"No alarm\"",
               mode(r.state), r.ac_va, r.battery_v, r.ac_v, r.ac_a);
        break;
    }
    case DEV_CABIN:
    case DEV_FRIDGE:
        // Filled in from the frame's own packet below.
        break;
    }
    printf("}");
}

static void emit(demo_device_t *d, sim_t *s, scene_t scene, int *first)
{
    uint8_t adv[ADV_MAX], rsp[ADV_MAX];
    size_t al = 0, rl = 0;
    printf("%s{\"scene\":\"%s\",\"name\":\"%s\",", *first ? "" : ",\n",
           scene_name(scene), d->name);
    *first = 0;
    if (d->kind == DEV_CABIN || d->kind == DEV_FRIDGE) {
        // BTHome: capture the reading the frame is built from.
        sim_t copy = *s;
        bthome_reading_t r;
        if (d->kind == DEV_CABIN) sim_cabin(&copy, &r); else sim_fridge(&copy, &r);
        demo_device_frames(d, s, adv, &al, rsp, &rl);
        printf("\"expect\":{\"temperature\":%.4f,\"battery\":%d", r.temperature_c,
               r.battery);
        if (r.humidity >= 0) printf(",\"humidity\":%.4f", r.humidity);
        printf("},");
    } else {
        expect(d, s);
        printf(",");
        demo_device_frames(d, s, adv, &al, rsp, &rl);
        hexs("key", d->key, 16);
        printf(",");
    }
    hexs("adv", adv, al);
    printf(",");
    hexs("rsp", rsp, rl);
    printf("}");
}

int main(void)
{
    sim_t s;
    sim_defaults(&s);
    sim_init(&s);
    int first = 1;
    // Include a Phoenix inverter even though the default line-up has the
    // MultiPlus, so both record types stay covered.
    demo_device_t inverter = {
        .kind = DEV_INVERTER,
        .name = "Inverter",
        .model = 0xA27A,
        .key = {0x4b, 0x1f, 0x80, 0x22, 0x9e, 0x6d, 0x31, 0xc4,
                0x07, 0xaa, 0x5e, 0x13, 0x68, 0xf0, 0xd2, 0x95},
    };
    printf("[\n");
    for (scene_t sc = 0; sc < SCENE_COUNT; sc++) {
        sim_set_scene(&s, sc);
        if (sc == SCENE_SHORE) s.soc = 95;  // reach absorption on shore
        for (int t = 0; t < 600; t++) sim_step(&s, 0.1f);
        for (size_t i = 0; i < demo_device_count; i++)
            emit(&demo_devices[i], &s, sc, &first);
        emit(&inverter, &s, sc, &first);
    }
    printf("\n]\n");
    return 0;
}
