// Le'Casa demo simulator - advertisement frame builders.
// Copyright (C) 2026 Chloe Madison and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Victron layouts follow victron-ble (MIT,
// https://github.com/keshavdv/victron-ble), the same source Le'Casa's
// decoder (lib/decoders/victron.dart) was ported from.

#include "frames.h"

#include <math.h>
#include <string.h>

// LSB-first bit writer, the mirror of Le'Casa's BitReader.
typedef struct {
    uint8_t *buf;
    size_t bit;
} bitw_t;

static void bw_put(bitw_t *w, uint32_t v, int bits)
{
    for (int i = 0; i < bits; i++, w->bit++) {
        uint8_t *b = &w->buf[w->bit >> 3];
        uint8_t m = 1u << (w->bit & 7);
        if ((v >> i) & 1) *b |= m; else *b &= (uint8_t)~m;
    }
}

static void bw_signed(bitw_t *w, int32_t v, int bits)
{
    bw_put(w, (uint32_t)v & ((bits == 32) ? 0xFFFFFFFFu : ((1u << bits) - 1)),
           bits);
}

// Unused trailing bits are sent as ones, like the real devices.
static size_t bw_finish(bitw_t *w, size_t bytes)
{
    while (w->bit < bytes * 8) bw_put(w, 1, 1);
    return bytes;
}

static int32_t clampi(double v, int32_t lo, int32_t hi)
{
    long r = lround(v);
    if (r < lo) return lo;
    if (r > hi) return hi;
    return (int32_t)r;
}

size_t victron_solar_record(uint8_t *out, const solar_reading_t *r)
{
    bitw_t w = {out, 0};
    bw_put(&w, r->state, 8);
    bw_put(&w, r->error, 8);
    bw_signed(&w, clampi(r->battery_v * 100, -32768, 32766), 16);
    bw_signed(&w, clampi(r->battery_a * 10, -32768, 32766), 16);
    bw_put(&w, (uint32_t)clampi(r->yield_today_wh / 10, 0, 0xFFFE), 16);
    bw_put(&w, (uint32_t)clampi(r->solar_w, 0, 0xFFFE), 16);
    bw_put(&w, r->load_a < 0 ? 0x1FF : (uint32_t)clampi(r->load_a * 10, 0, 0x1FE),
           9);
    return bw_finish(&w, 12);
}

size_t victron_shunt_record(uint8_t *out, const shunt_reading_t *r)
{
    bitw_t w = {out, 0};
    bw_put(&w, r->time_to_go_min < 0 ? 0xFFFF
                                     : (uint32_t)clampi(r->time_to_go_min, 0, 0xFFFE),
           16);
    bw_signed(&w, clampi(r->voltage * 100, -32768, 32766), 16);
    bw_put(&w, r->alarm, 16);
    // Aux input in temperature mode: kelvin in 0.01 K.
    bw_put(&w, (uint32_t)clampi((r->temperature_c + 273.15) * 100, 0, 0xFFFE), 16);
    bw_put(&w, 2, 2);  // aux mode 2 = temperature
    bw_signed(&w, clampi(r->current * 1000, -(1 << 21), (1 << 21) - 2), 22);
    bw_put(&w, (uint32_t)clampi(r->consumed_ah * 10, 0, 0xFFFFE), 20);
    bw_put(&w, (uint32_t)clampi(r->soc * 10, 0, 1000), 10);
    return bw_finish(&w, 16);
}

size_t victron_inverter_record(uint8_t *out, const inverter_reading_t *r)
{
    bitw_t w = {out, 0};
    bw_put(&w, r->state, 8);
    bw_put(&w, r->alarm, 16);
    bw_signed(&w, clampi(r->battery_v * 100, -32768, 32766), 16);
    bw_put(&w, (uint32_t)clampi(r->ac_va, 0, 0xFFFE), 16);
    bw_put(&w, (uint32_t)clampi(r->ac_v * 100, 0, 0x7FFE), 15);
    bw_put(&w, (uint32_t)clampi(r->ac_a * 10, 0, 0x7FE), 11);
    return bw_finish(&w, 11);
}

size_t victron_vebus_record(uint8_t *out, const vebus_reading_t *r)
{
    bitw_t w = {out, 0};
    bw_put(&w, r->state, 8);
    bw_put(&w, r->error, 8);
    bw_signed(&w, clampi(r->battery_a * 10, -32768, 32766), 16);
    bw_put(&w, (uint32_t)clampi(r->battery_v * 100, 0, 0x3FFE), 14);
    bw_put(&w, r->ac_in_state & 3, 2);
    bw_signed(&w, clampi(r->ac_in_w, -(1 << 18), (1 << 18) - 2), 19);
    bw_signed(&w, clampi(r->ac_out_w, -(1 << 18), (1 << 18) - 2), 19);
    bw_put(&w, 0, 2);  // alarm: none
    bw_put(&w, (uint32_t)clampi(r->battery_temp_c + 40, 0, 0x7E), 7);
    bw_put(&w, r->soc < 0 ? 0x7F : (uint32_t)clampi(r->soc, 0, 100), 7);
    return bw_finish(&w, 13);
}

size_t victron_mfr_data(uint8_t *out, const uint8_t key[16], uint16_t model,
                        uint8_t record, uint16_t iv, const uint8_t *plain,
                        size_t plain_len)
{
    if (plain_len > 16) return 0;
    size_t n = 0;
    out[n++] = 0xE1;  // company id 0x02E1, little-endian
    out[n++] = 0x02;
    out[n++] = 0x10;  // product advertisement
    out[n++] = 0x02;
    out[n++] = model & 0xFF;
    out[n++] = model >> 8;
    out[n++] = record;
    out[n++] = iv & 0xFF;
    out[n++] = iv >> 8;
    out[n++] = key[0];
    // AES-128-CTR, counter = iv as a little-endian 128-bit number. One
    // block covers every record we send.
    uint8_t ctr[16] = {0}, ks[16];
    ctr[0] = iv & 0xFF;
    ctr[1] = iv >> 8;
    aes128_encrypt_block(key, ctr, ks);
    for (size_t i = 0; i < plain_len; i++) out[n++] = plain[i] ^ ks[i];
    return n;
}

static size_t put_le(uint8_t *out, int32_t v, int bytes)
{
    for (int i = 0; i < bytes; i++) out[i] = ((uint32_t)v >> (8 * i)) & 0xFF;
    return bytes;
}

size_t bthome_service_data(uint8_t *out, const bthome_reading_t *r)
{
    size_t n = 0;
    out[n++] = 0xD2;  // UUID 0xFCD2, little-endian
    out[n++] = 0xFC;
    out[n++] = 0x40;  // BTHome v2, not encrypted, regular interval
    // Objects must go in ascending id order.
    out[n++] = 0x00;
    out[n++] = r->packet_id;
    if (r->battery >= 0) {
        out[n++] = 0x01;
        out[n++] = (uint8_t)clampi(r->battery, 0, 100);
    }
    out[n++] = 0x02;
    n += put_le(out + n, clampi(r->temperature_c * 100, -32768, 32767), 2);
    if (r->humidity >= 0) {
        out[n++] = 0x03;
        n += put_le(out + n, clampi(r->humidity * 100, 0, 10000), 2);
    }
    return n;
}

static const uint8_t flags_ad[] = {0x02, 0x01, 0x06};

size_t adv_with_mfr(uint8_t *out, const uint8_t *mfr, size_t mfr_len)
{
    size_t n = sizeof flags_ad + 2 + mfr_len;
    if (n > ADV_MAX) return 0;
    memcpy(out, flags_ad, sizeof flags_ad);
    out[3] = (uint8_t)(mfr_len + 1);
    out[4] = 0xFF;
    memcpy(out + 5, mfr, mfr_len);
    return n;
}

size_t adv_with_service_data(uint8_t *out, const uint8_t *sd, size_t sd_len,
                             const char *name)
{
    size_t n = sizeof flags_ad;
    memcpy(out, flags_ad, n);
    if (n + 2 + sd_len > ADV_MAX) return 0;
    out[n++] = (uint8_t)(sd_len + 1);
    out[n++] = 0x16;
    memcpy(out + n, sd, sd_len);
    n += sd_len;
    // BTHome sensors carry their name in the advert itself.
    size_t len = name ? strlen(name) : 0;
    if (len && n + 2 <= ADV_MAX) {
        size_t room = ADV_MAX - n - 2;
        bool complete = len <= room;
        if (!complete) len = room;
        out[n++] = (uint8_t)(len + 1);
        out[n++] = complete ? 0x09 : 0x08;
        memcpy(out + n, name, len);
        n += len;
    }
    return n;
}

size_t scan_rsp_name(uint8_t *out, const char *name)
{
    size_t len = strlen(name);
    if (len > ADV_MAX - 2) len = ADV_MAX - 2;
    out[0] = (uint8_t)(len + 1);
    out[1] = 0x09;
    memcpy(out + 2, name, len);
    return len + 2;
}
