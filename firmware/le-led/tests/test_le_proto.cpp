// Host tests for le_proto.cpp. Build and run with:  make -C tests
//
// AES comes from OpenSSL here; on the ESP32 it is the hardware block.
//
// SPDX-License-Identifier: EUPL-1.2

#include <openssl/aes.h>
#include <stdio.h>
#include <string.h>

#include "../le_proto.h"

static int failures;

static void check(bool cond, const char *what) {
  printf("  %-60s %s\n", what, cond ? "ok" : "FAIL");
  if (!cond) failures++;
}

static void unhex(uint8_t *out, const char *hex) {
  while (hex[0] && hex[1]) {
    unsigned v;
    if (hex[0] == ' ') {
      hex++;
      continue;
    }
    sscanf(hex, "%2x", &v);
    *out++ = (uint8_t)v;
    hex += 2;
  }
}

static void ossl_aes(const uint8_t key[16], const uint8_t in[16],
                     uint8_t out[16]) {
  AES_KEY k;
  AES_set_encrypt_key(key, 128, &k);
  AES_encrypt(in, out, &k);
}

static void print_hex(const char *label, const uint8_t *p, size_t n) {
  printf("    %s ", label);
  for (size_t i = 0; i < n; i++) printf("%02x", p[i]);
  printf("\n");
}

int main() {
  le_set_aes(ossl_aes);

  printf("BTHome encryption (bthome.io published example)\n");
  {
    uint8_t key[16], mac[6], body[15], plain[16];
    unhex(key, "231d39c1d7cc1ab1aee224cd096db932");
    unhex(mac, "5448e68f80a5");
    unhex(body, "41 a4 72 66 c9 5f 73 00 11 22 33 78 23 72 14");
    uint32_t ctr = 0;
    int n = bthome_decrypt(key, mac, body, sizeof(body), plain, &ctr);
    uint8_t want[6];
    unhex(want, "02ca09 03bf13");
    check(n == 6 && memcmp(plain, want, 6) == 0,
          "decrypts to temperature 25.06 C + humidity 50.55 %");
    check(ctr == 0x33221100, "counter read little-endian");

    body[3] ^= 1;
    check(bthome_decrypt(key, mac, body, sizeof(body), plain, &ctr) < 0,
          "one flipped bit is rejected");
    body[3] ^= 1;
    uint8_t other[16];
    memcpy(other, key, 16);
    other[0] ^= 0x80;
    check(bthome_decrypt(other, mac, body, sizeof(body), plain, &ctr) < 0,
          "wrong key is rejected");

    // Wrapped in a full advert and found again.
    uint8_t adv[31] = {0x02, 0x01, 0x06, (uint8_t)(3 + sizeof(body)), 0x16,
                       0xD2, 0xFC};
    memcpy(adv + 7, body, sizeof(body));
    const uint8_t *found = nullptr;
    size_t fl = bthome_find(adv, 7 + sizeof(body), &found);
    check(fl == sizeof(body) && found == adv + 7, "bthome_find locates it");
  }

  printf("CCM with associated data round trip\n");
  {
    uint8_t key[16], nonce[13], aad[9], msg[20], copy[20], mic[4];
    for (int i = 0; i < 16; i++) key[i] = (uint8_t)(i * 11 + 1);
    for (int i = 0; i < 13; i++) nonce[i] = (uint8_t)(i * 3);
    for (int i = 0; i < 9; i++) aad[i] = (uint8_t)(0xA0 + i);
    for (int i = 0; i < 20; i++) msg[i] = copy[i] = (uint8_t)(i * 7);
    le_ccm_encrypt(key, nonce, aad, 9, msg, 20, mic);
    check(memcmp(msg, copy, 20) != 0, "ciphertext differs from plaintext");
    check(le_ccm_decrypt(key, nonce, aad, 9, msg, 20, mic) &&
              memcmp(msg, copy, 20) == 0,
          "decrypts back over two blocks");
    le_ccm_encrypt(key, nonce, aad, 9, msg, 20, mic);
    aad[4] ^= 1;
    check(!le_ccm_decrypt(key, nonce, aad, 9, msg, 20, mic),
          "tampered associated data is rejected");
  }

  printf("Le'LED state advert\n");
  {
    uint8_t key[16], mac[6];
    unhex(key, "00112233445566778899aabbccddeeff");
    unhex(mac, "a0b1c2d3e4f5");
    LedState s = {true, 128, 255, 64, 0, 10, 9, 3, 200, 100, 7};
    uint8_t adv[31];
    size_t n = le_build_state_adv(key, mac, 1000, s, 5, lep_ack_byte(2, 77),
                                  adv);
    check(n == 30, "fits a legacy advert (30 bytes)");
    print_hex("advert", adv, n);

    const uint8_t *body = nullptr;
    size_t bl = bthome_find(adv, n, &body);
    uint8_t plain[32];
    uint32_t ctr = 0;
    int pl = bthome_decrypt(key, mac, body, bl, plain, &ctr);
    check(pl == 14 && ctr == 1000, "a BTHome receiver decrypts it");
    check(plain[0] == 0x10 && plain[1] == 1, "power object 0x10 = on");
    check(plain[2] == 0x54 && plain[3] == 10, "raw object 0x54, 10 bytes");
    check(plain[4] == 5 && plain[5] == ((2 << 6) | (77 & 0x3F)),
          "revision and ack byte");
    check(plain[6] == 128, "brightness");
    uint8_t r, g, b;
    rgb_from_565((uint16_t)(plain[7] | plain[8] << 8), &r, &g, &b);
    check(r == 255 && g == 65 && b == 0, "colour survives RGB565");
    check(plain[9] == 9 && plain[10] == 3 && plain[11] == 200 &&
              plain[12] == 100 && plain[13] == 7,
          "effect, palette, speed, intensity, preset");
  }

  printf("Le'LED MAC advert\n");
  {
    uint8_t key[16], mac[6];
    unhex(key, "00112233445566778899aabbccddeeff");
    unhex(mac, "a0b1c2d3e4f5");
    uint8_t adv[31];
    size_t n = le_build_mac_adv(key, mac, 1001, true, adv);
    check(n == 27, "fits a legacy advert (27 bytes)");
    print_hex("advert", adv, n);
    const uint8_t *body = nullptr;
    size_t bl = bthome_find(adv, n, &body);
    check(bl == 1 + 6 + 5 + 8 && body[0] == 0x43, "info 0x43: MAC included");
    check(body[1] == 0xf5 && body[6] == 0xa0, "MAC in the clear, reversed");
    // bthome_decrypt takes the body without the MAC.
    uint8_t rest[32];
    rest[0] = body[0];
    memcpy(rest + 1, body + 7, bl - 7);
    uint8_t plain[32];
    uint32_t ctr = 0;
    int pl = bthome_decrypt(key, mac, rest, bl - 6, plain, &ctr);
    check(pl == 5 && ctr == 1001, "decrypts with the MAC it carries");
    check(plain[0] == 0x10 && plain[1] == 1 && plain[2] == 0x54 &&
              plain[3] == 1 && plain[4] == LE_MAC_ADV_MARK,
          "power, and the 1-byte Le'LED mark");
  }

  printf("Le'Proto compact frame\n");
  {
    uint8_t key[16];
    unhex(key, "00112233445566778899aabbccddeeff");
    LepKeys k;
    lep_derive(key, &k);
    print_hex("down key", k.down, 16);
    print_hex("dst id  ", k.dst, 3);

    LepCommand c = {1, 42, 0, LEP_OP_BRIGHTNESS, 200, 3};
    uint8_t f[16];
    lep_seal(k, c, f);
    print_hex("frame   ", f, 16);
    check(f[0] == 0x4C && f[1] == 0x01, "magic and type");
    check(memcmp(f + 2, k.dst, 3) == 0, "destination id");
    check(f[5] == 1 && f[6] == 42 && f[7] == 0 && f[8] == 0,
          "slot and sequence in the clear");
    check(!(f[9] == LEP_OP_BRIGHTNESS && f[10] == 200),
          "payload is encrypted");

    uint32_t last[LEP_SLOTS] = {0, 0, 0, 0};
    LepCommand got;
    check(lep_open(k, f, last, &got) == LEP_OK && got.opcode == 2 &&
              got.a0 == 200 && got.a1 == 3 && got.slot == 1 && got.seq == 42,
          "opens and decrypts");
    check(last[1] == 42, "replay window advanced");
    check(lep_open(k, f, last, &got) == LEP_REPLAY,
          "the same frame again is a replay");

    c.seq = 41;
    lep_seal(k, c, f);
    check(lep_open(k, f, last, &got) == LEP_REPLAY, "an older seq is a replay");
    c.seq = 43;
    lep_seal(k, c, f);
    check(lep_open(k, f, last, &got) == LEP_OK, "the next seq is accepted");

    c.slot = 2;
    c.seq = 1;
    lep_seal(k, c, f);
    check(lep_open(k, f, last, &got) == LEP_OK,
          "another screen's slot has its own window");

    c.seq = 50;
    lep_seal(k, c, f);
    f[10] ^= 4;
    check(lep_open(k, f, last, &got) == LEP_BAD_MIC, "tampered payload");
    f[10] ^= 4;
    f[6] ^= 1;
    check(lep_open(k, f, last, &got) == LEP_BAD_MIC,
          "tampered sequence (authenticated header)");
    f[6] ^= 1;

    uint8_t other[16];
    unhex(other, "ffeeddccbbaa99887766554433221100");
    LepKeys k2;
    lep_derive(other, &k2);
    check(lep_open(k2, f, last, &got) == LEP_NOT_OURS,
          "another light ignores it (destination id)");

    // Both transports.
    uint8_t adv[31], back[16];
    size_t n = lep_build_mfr_adv(f, adv);
    check(n == 23 && lep_find(adv, n, back) && memcmp(back, f, 16) == 0,
          "found in manufacturer data (Android, ESP32)");
    uint8_t ios[21] = {0x02, 0x01, 0x06, 17, 0x07};
    memcpy(ios + 5, f, 16);
    memset(back, 0, 16);
    check(lep_find(ios, 21, back) && memcmp(back, f, 16) == 0,
          "found as a 128-bit service UUID (iOS)");
    uint8_t junk[] = {0x02, 0x01, 0x06, 0x05, 0xFF, 0x4C, 0x00, 0x10, 0x05};
    check(!lep_find(junk, sizeof(junk), back), "Apple adverts are ignored");
  }

  printf("Opcode to WLED JSON\n");
  {
    LedState cur = {true, 100, 10, 20, 30, 40, 0, 0, 128, 128, 0};
    char j[96];
    LepCommand c = {0, 1, 0, LEP_OP_POWER, 0, 5};
    lep_to_json(c, cur, j, sizeof j);
    check(strcmp(j, "{\"on\":false,\"tt\":5}") == 0, j);
    c.opcode = LEP_OP_COLOR;
    uint16_t v = rgb_to_565(255, 0, 0);
    c.a0 = (uint8_t)v;
    c.a1 = (uint8_t)(v >> 8);
    lep_to_json(c, cur, j, sizeof j);
    check(strcmp(j, "{\"seg\":{\"col\":[[255,0,0,40]]}}") == 0, j);
    c.opcode = LEP_OP_WHITE;
    c.a0 = 200;
    lep_to_json(c, cur, j, sizeof j);
    check(strcmp(j, "{\"seg\":{\"col\":[[10,20,30,200]]}}") == 0, j);
    c.opcode = LEP_OP_CCT;
    c.a0 = 2700 & 0xFF;
    c.a1 = 2700 >> 8;
    lep_to_json(c, cur, j, sizeof j);
    check(strcmp(j, "{\"seg\":{\"cct\":2700}}") == 0, j);
    c.opcode = LEP_OP_PRESET;
    c.a0 = 0;
    check(lep_to_json(c, cur, j, sizeof j) == 0, "preset 0 is refused");
    c.opcode = LEP_OP_WAKE;
    check(lep_to_json(c, cur, j, sizeof j) == 0, "wake is not a state change");
    bthome_command_to_json(BTHOME_CMD_STEP_DOWN, 2, j, sizeof j);
    check(strcmp(j, "{\"bri\":\"~-32\"}") == 0, j);
  }

  printf("Le'Fob style button frame\n");
  {
    // Packet id 7, four buttons, button 3 long-pressed.
    uint8_t objs[] = {0x00, 7, 0x3A, 0, 0x3A, 0, 0x3A, 4, 0x3A, 0};
    BthomeEvents ev;
    bthome_parse_events(objs, sizeof objs, &ev);
    check(ev.has_packet_id && ev.packet_id == 7, "packet id");
    check(ev.buttons == 4 && ev.button[2] == BTHOME_EVT_LONG_PRESS,
          "four buttons, the third long-pressed");

    // A chirp frame: temperature, voltage, text. No buttons.
    uint8_t chirp[] = {0x00, 9, 0x02, 0x10, 0x09, 0x0C, 0xE4, 0x0C,
                       0x53, 3, 'U', 'S', 'B'};
    bthome_parse_events(chirp, sizeof chirp, &ev);
    check(ev.buttons == 0 && ev.packet_id == 9, "status chirp has no buttons");

    // Encrypt a button frame like the fob does and decrypt it back.
    uint8_t key[16], mac[6];
    unhex(key, "0f1e2d3c4b5a69788796a5b4c3d2e1f0");
    unhex(mac, "84c2e4010203");
    uint8_t body[1 + sizeof objs + 8];
    body[0] = 0x45; // v2, trigger based, encrypted
    memcpy(body + 1, objs, sizeof objs);
    uint8_t nonce[13];
    uint32_t ctr = 123456;
    bthome_nonce(nonce, mac, 0x45, ctr);
    uint8_t *ct = body + 1;
    uint8_t mic[4];
    le_ccm_encrypt(key, nonce, nullptr, 0, ct, sizeof objs, mic);
    uint8_t *tail = body + 1 + sizeof objs;
    tail[0] = (uint8_t)ctr;
    tail[1] = (uint8_t)(ctr >> 8);
    tail[2] = (uint8_t)(ctr >> 16);
    tail[3] = (uint8_t)(ctr >> 24);
    memcpy(tail + 4, mic, 4);
    uint8_t plain[32];
    uint32_t got = 0;
    int n = bthome_decrypt(key, mac, body, sizeof body, plain, &got);
    bthome_parse_events(plain, (size_t)n, &ev);
    check(n == (int)sizeof objs && got == ctr && ev.button[2] == 4,
          "encrypted fob frame decrypts to the same events");
  }

  printf("Keys\n");
  {
    uint8_t k[16];
    char hex[33];
    check(le_hex_to_key("23:1d:39:c1 d7cc1ab1aee224cd096db932", k),
          "hex with separators parses");
    le_key_to_hex(k, hex);
    check(strcmp(hex, "231d39c1d7cc1ab1aee224cd096db932") == 0,
          "prints back");
    check(!le_hex_to_key("231d", k), "short key refused");
    check(!le_hex_to_key("zz1d39c1d7cc1ab1aee224cd096db932", k),
          "non-hex refused");
  }

  printf(failures ? "\n%d FAILED\n" : "\nall passed\n", failures);
  return failures ? 1 : 0;
}
