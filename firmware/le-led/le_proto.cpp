// Le'Proto v0. See le_proto.h and PROTOCOL.md.
//
// SPDX-License-Identifier: EUPL-1.2

#include "le_proto.h"

#include <stdio.h>
#include <string.h>

// ---- AES ---------------------------------------------------------------

static le_aes_fn g_aes = nullptr;

void le_set_aes(le_aes_fn fn) { g_aes = fn; }

void le_aes(const uint8_t key[16], const uint8_t in[16], uint8_t out[16]) {
  g_aes(key, in, out);
}

// ---- AES-CCM -----------------------------------------------------------
//
// RFC 3610 with M = 4 (MIC length) and L = 2 (length field), so the nonce is
// 15 - L = 13 bytes. Messages here are at most a few dozen bytes.

static void ccm_mac(const uint8_t key[16], const uint8_t nonce[13],
                    const uint8_t *aad, size_t aad_len, const uint8_t *msg,
                    size_t len, uint8_t tag[16]) {
  uint8_t b[16], x[16];

  // B0: flags, nonce, message length.
  b[0] = (uint8_t)((aad_len ? 0x40 : 0) | (((4 - 2) / 2) << 3) | (2 - 1));
  memcpy(b + 1, nonce, 13);
  b[14] = (uint8_t)(len >> 8);
  b[15] = (uint8_t)len;
  le_aes(key, b, x);

  // Associated data: 2-byte length, then the bytes, zero padded.
  if (aad_len) {
    uint8_t blk[16];
    size_t i = 0, pos = 2;

    memset(blk, 0, 16);
    blk[0] = (uint8_t)(aad_len >> 8);
    blk[1] = (uint8_t)aad_len;
    while (i < aad_len) {
      blk[pos++] = aad[i++];
      if (pos == 16 || i == aad_len) {
        for (int j = 0; j < 16; j++) x[j] ^= blk[j];
        le_aes(key, x, x);
        memset(blk, 0, 16);
        pos = 0;
      }
    }
  }

  // Message blocks, zero padded.
  for (size_t off = 0; off < len; off += 16) {
    size_t n = len - off < 16 ? len - off : 16;
    for (size_t j = 0; j < n; j++) x[j] ^= msg[off + j];
    le_aes(key, x, x);
  }
  memcpy(tag, x, 16);
}

static void ccm_ctr(const uint8_t key[16], const uint8_t nonce[13],
                    uint8_t *buf, size_t len, uint8_t s0[16]) {
  uint8_t a[16], s[16];

  a[0] = 2 - 1;
  memcpy(a + 1, nonce, 13);
  a[14] = 0;
  a[15] = 0;
  le_aes(key, a, s0);

  uint16_t ctr = 1;
  for (size_t off = 0; off < len; off += 16, ctr++) {
    a[14] = (uint8_t)(ctr >> 8);
    a[15] = (uint8_t)ctr;
    le_aes(key, a, s);
    size_t n = len - off < 16 ? len - off : 16;
    for (size_t j = 0; j < n; j++) buf[off + j] ^= s[j];
  }
}

void le_ccm_encrypt(const uint8_t key[16], const uint8_t nonce[13],
                    const uint8_t *aad, size_t aad_len, uint8_t *buf,
                    size_t len, uint8_t mic[4]) {
  uint8_t tag[16], s0[16];

  ccm_mac(key, nonce, aad, aad_len, buf, len, tag);
  ccm_ctr(key, nonce, buf, len, s0);
  for (int i = 0; i < 4; i++) mic[i] = tag[i] ^ s0[i];
}

bool le_ccm_decrypt(const uint8_t key[16], const uint8_t nonce[13],
                    const uint8_t *aad, size_t aad_len, uint8_t *buf,
                    size_t len, const uint8_t mic[4]) {
  uint8_t tag[16], s0[16];

  ccm_ctr(key, nonce, buf, len, s0);
  ccm_mac(key, nonce, aad, aad_len, buf, len, tag);

  uint8_t diff = 0;
  for (int i = 0; i < 4; i++) diff |= (uint8_t)(mic[i] ^ tag[i] ^ s0[i]);
  if (diff) {
    // Put the ciphertext back so a caller trying several keys can retry.
    ccm_ctr(key, nonce, buf, len, s0);
    return false;
  }
  return true;
}

// ---- AD structures -------------------------------------------------------

// Calls fn(type, data, len) for each AD structure until it returns true.
template <typename F>
static bool each_ad(const uint8_t *adv, size_t adv_len, F fn) {
  size_t i = 0;
  while (i < adv_len) {
    uint8_t l = adv[i];
    if (l == 0) break;
    if (i + 1 + l > adv_len) break;
    if (fn(adv[i + 1], adv + i + 2, (size_t)(l - 1))) return true;
    i += 1 + l;
  }
  return false;
}

// ---- BTHome ------------------------------------------------------------

void bthome_nonce(uint8_t nonce[13], const uint8_t mac[6], uint8_t info,
                  uint32_t counter) {
  memcpy(nonce, mac, 6);
  nonce[6] = (uint8_t)(BTHOME_UUID & 0xFF);
  nonce[7] = (uint8_t)(BTHOME_UUID >> 8);
  nonce[8] = info;
  nonce[9] = (uint8_t)counter;
  nonce[10] = (uint8_t)(counter >> 8);
  nonce[11] = (uint8_t)(counter >> 16);
  nonce[12] = (uint8_t)(counter >> 24);
}

size_t bthome_find(const uint8_t *adv, size_t adv_len, const uint8_t **out) {
  size_t found = 0;
  each_ad(adv, adv_len, [&](uint8_t type, const uint8_t *d, size_t n) {
    if (type == 0x16 && n >= 3 && d[0] == (BTHOME_UUID & 0xFF) &&
        d[1] == (BTHOME_UUID >> 8)) {
      *out = d + 2;
      found = n - 2;
      return true;
    }
    return false;
  });
  return found;
}

int bthome_decrypt(const uint8_t key[16], const uint8_t mac[6],
                   const uint8_t *body, size_t body_len, uint8_t *plain,
                   uint32_t *counter_out) {
  // info byte, ciphertext (>= 1), counter (4), MIC (4)
  if (body_len < 1 + 1 + 8) return -1;
  uint8_t info = body[0];
  if (!(info & BTHOME_INFO_ENCRYPTED)) return -1;
  if ((info >> 5) != 2) return -1;

  size_t clen = body_len - 1 - 8;
  const uint8_t *ctr = body + 1 + clen;
  uint32_t counter = (uint32_t)ctr[0] | (uint32_t)ctr[1] << 8 |
                     (uint32_t)ctr[2] << 16 | (uint32_t)ctr[3] << 24;
  uint8_t nonce[13];
  bthome_nonce(nonce, mac, info, counter);

  memcpy(plain, body + 1, clen);
  if (!le_ccm_decrypt(key, nonce, nullptr, 0, plain, clen, ctr + 4))
    return -1;
  if (counter_out) *counter_out = counter;
  return (int)clen;
}

// Sizes of the fixed-length objects we might meet before the ones we want.
// 0 = unknown (stop), 255 = variable length (next byte is the length).
static uint8_t obj_size(uint8_t id) {
  switch (id) {
  case 0x00: case 0x01: case 0x09: case 0x0F: case 0x10: case 0x11:
  case 0x15: case 0x16: case 0x17: case 0x18: case 0x19: case 0x1A:
  case 0x1B: case 0x1C: case 0x1D: case 0x1E: case 0x1F: case 0x20:
  case 0x21: case 0x22: case 0x23: case 0x24: case 0x25: case 0x26:
  case 0x27: case 0x28: case 0x29: case 0x2A: case 0x2B: case 0x2C:
  case 0x2D: case 0x2E: case 0x2F: case 0x3A: case 0x46: case 0x57:
  case 0x58: case 0x59: case 0x60:
    return 1;
  case 0x02: case 0x03: case 0x06: case 0x07: case 0x08: case 0x0C:
  case 0x0D: case 0x0E: case 0x12: case 0x13: case 0x14: case 0x3C:
  case 0x3D: case 0x3F: case 0x40: case 0x41: case 0x43: case 0x44:
  case 0x45: case 0x47: case 0x48: case 0x51: case 0x52: case 0x56:
  case 0x5E: case 0x5F: case 0x61:
    return 2;
  case 0x04: case 0x0A: case 0x0B: case 0x42: case 0x4A: case 0x4B:
    return 3;
  case 0x3E: case 0x49: case 0x4C: case 0x4D: case 0x4E: case 0x4F:
  case 0x50: case 0x55: case 0x5A: case 0x5B: case 0x5C: case 0x5D:
    return 4;
  case 0x3B: case 0x53: case 0x54:
    return 255;
  default:
    return 0;
  }
}

void bthome_parse_events(const uint8_t *p, size_t len, BthomeEvents *ev) {
  memset(ev, 0, sizeof(*ev));
  size_t i = 0;
  while (i < len) {
    uint8_t id = p[i++];
    uint8_t sz = obj_size(id);
    if (sz == 0) return;
    if (sz == 255) {
      if (i >= len) return;
      sz = p[i++];
      if (i + sz > len) return;
      if (id == BTHOME_OBJ_COMMAND && sz >= 1) {
        ev->has_command = true;
        ev->command = p[i];
        ev->command_arg = sz >= 2 ? p[i + 1] : 0;
      }
      i += sz;
      continue;
    }
    if (i + sz > len) return;
    if (id == BTHOME_OBJ_PACKET_ID) {
      ev->has_packet_id = true;
      ev->packet_id = p[i];
    } else if (id == BTHOME_OBJ_BUTTON && ev->buttons < 8) {
      ev->button[ev->buttons++] = p[i];
    }
    i += sz;
  }
}

// ---- State --------------------------------------------------------------

uint16_t rgb_to_565(uint8_t r, uint8_t g, uint8_t b) {
  return (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
}

void rgb_from_565(uint16_t v, uint8_t *r, uint8_t *g, uint8_t *b) {
  uint8_t r5 = (v >> 11) & 0x1F, g6 = (v >> 5) & 0x3F, b5 = v & 0x1F;
  *r = (uint8_t)((r5 << 3) | (r5 >> 2));
  *g = (uint8_t)((g6 << 2) | (g6 >> 4));
  *b = (uint8_t)((b5 << 3) | (b5 >> 2));
}

void le_state_pack(const LedState &s, uint8_t rev, uint8_t ack,
                   uint8_t out[LE_STATE_RAW_LEN]) {
  uint16_t c = rgb_to_565(s.r, s.g, s.b);
  out[0] = rev;
  out[1] = ack;
  out[2] = s.bri;
  out[3] = (uint8_t)c;
  out[4] = (uint8_t)(c >> 8);
  out[5] = s.fx;
  out[6] = s.pal;
  out[7] = s.sx;
  out[8] = s.ix;
  out[9] = s.preset;
}

size_t le_build_state_adv(const uint8_t key[16], const uint8_t mac[6],
                          uint32_t counter, const LedState &s, uint8_t rev,
                          uint8_t ack, uint8_t out[31]) {
  const uint8_t info = BTHOME_INFO_V2 | BTHOME_INFO_ENCRYPTED; // 0x41
  uint8_t plain[2 + 2 + LE_STATE_RAW_LEN];
  size_t n = 0;

  plain[n++] = BTHOME_OBJ_POWER;
  plain[n++] = s.on ? 1 : 0;
  plain[n++] = BTHOME_OBJ_RAW;
  plain[n++] = LE_STATE_RAW_LEN;
  le_state_pack(s, rev, ack, plain + n);
  n += LE_STATE_RAW_LEN;

  uint8_t nonce[13];
  bthome_nonce(nonce, mac, info, counter);
  uint8_t mic[4];
  le_ccm_encrypt(key, nonce, nullptr, 0, plain, n, mic);

  size_t o = 0;
  out[o++] = 0x02; // flags
  out[o++] = 0x01;
  out[o++] = 0x06;
  out[o++] = (uint8_t)(1 + 2 + 1 + n + 8); // AD length
  out[o++] = 0x16;                         // service data, 16-bit UUID
  out[o++] = (uint8_t)(BTHOME_UUID & 0xFF);
  out[o++] = (uint8_t)(BTHOME_UUID >> 8);
  out[o++] = info;
  memcpy(out + o, plain, n);
  o += n;
  out[o++] = (uint8_t)counter;
  out[o++] = (uint8_t)(counter >> 8);
  out[o++] = (uint8_t)(counter >> 16);
  out[o++] = (uint8_t)(counter >> 24);
  memcpy(out + o, mic, 4);
  o += 4;
  return o;
}

// ---- Le'Proto frame --------------------------------------------------------

void lep_derive(const uint8_t key[16], LepKeys *k) {
  static const uint8_t down_label[16] = {'L', 'e', 'P', 'r', 'o', 't', 'o', '-',
                                         'd', 'o', 'w', 'n', '-', 'v', '0', 0};
  static const uint8_t dst_label[16] = {'L', 'e', 'P', 'r', 'o', 't', 'o', '-',
                                        'd', 's', 't', 'i', 'd', '-', 'v', '0'};
  uint8_t t[16];

  memcpy(k->key, key, 16);
  le_aes(key, down_label, k->down);
  le_aes(key, dst_label, t);
  memcpy(k->dst, t, 3);
}

static void lep_nonce(uint8_t nonce[13], const uint8_t frame[16],
                      uint8_t direction) {
  memcpy(nonce, frame + 2, 3);     // dst
  nonce[3] = frame[5];             // src slot
  memcpy(nonce + 4, frame + 6, 3); // seq
  nonce[7] = frame[1];             // type and flags
  nonce[8] = direction;            // 0x01 = to the device
  nonce[9] = 'L';
  nonce[10] = 'E';
  nonce[11] = 'P';
  nonce[12] = 'R';
}

void lep_seal(const LepKeys &k, const LepCommand &c, uint8_t out[16]) {
  out[0] = LEP_MAGIC;
  out[1] = (uint8_t)(LEP_TYPE_COMMAND | (c.flags & 0x30));
  memcpy(out + 2, k.dst, 3);
  out[5] = c.slot & 3;
  out[6] = (uint8_t)c.seq;
  out[7] = (uint8_t)(c.seq >> 8);
  out[8] = (uint8_t)(c.seq >> 16);
  out[9] = c.opcode;
  out[10] = c.a0;
  out[11] = c.a1;

  uint8_t nonce[13];
  lep_nonce(nonce, out, 0x01);
  le_ccm_encrypt(k.down, nonce, out, 9, out + 9, 3, out + 12);
}

LepResult lep_open(const LepKeys &k, const uint8_t frame[16],
                   uint32_t last_seq[LEP_SLOTS], LepCommand *c) {
  if (frame[0] != LEP_MAGIC) return LEP_NOT_OURS;
  if ((frame[1] & 0x0F) != LEP_TYPE_COMMAND || (frame[1] >> 6) != 0)
    return LEP_NOT_OURS;
  if (memcmp(frame + 2, k.dst, 3) != 0) return LEP_NOT_OURS;
  if (frame[5] >= LEP_SLOTS) return LEP_NOT_OURS;

  uint8_t nonce[13], p[3];
  lep_nonce(nonce, frame, 0x01);
  memcpy(p, frame + 9, 3);
  if (!le_ccm_decrypt(k.down, nonce, frame, 9, p, 3, frame + 12))
    return LEP_BAD_MIC;

  uint8_t slot = frame[5];
  uint32_t seq = (uint32_t)frame[6] | (uint32_t)frame[7] << 8 |
                 (uint32_t)frame[8] << 16;
  if (seq == 0 || seq <= last_seq[slot]) return LEP_REPLAY;
  last_seq[slot] = seq;

  c->slot = slot;
  c->seq = seq;
  c->flags = frame[1] & 0x30;
  c->opcode = p[0];
  c->a0 = p[1];
  c->a1 = p[2];
  return LEP_OK;
}

bool lep_find(const uint8_t *adv, size_t adv_len, uint8_t frame[16]) {
  return each_ad(adv, adv_len, [&](uint8_t type, const uint8_t *d, size_t n) {
    // Manufacturer data: company id (LE) then our 16 bytes.
    if (type == 0xFF && n == 18 && d[0] == (LEP_MFR_ID & 0xFF) &&
        d[1] == (LEP_MFR_ID >> 8) && d[2] == LEP_MAGIC) {
      memcpy(frame, d + 2, 16);
      return true;
    }
    // 128-bit service UUID list (complete or incomplete): one UUID.
    if ((type == 0x06 || type == 0x07) && n == 16 && d[0] == LEP_MAGIC) {
      memcpy(frame, d, 16);
      return true;
    }
    return false;
  });
}

size_t lep_build_mfr_adv(const uint8_t frame[16], uint8_t out[31]) {
  size_t o = 0;
  out[o++] = 0x02;
  out[o++] = 0x01;
  out[o++] = 0x06;
  out[o++] = 1 + 2 + 16;
  out[o++] = 0xFF;
  out[o++] = (uint8_t)(LEP_MFR_ID & 0xFF);
  out[o++] = (uint8_t)(LEP_MFR_ID >> 8);
  memcpy(out + o, frame, 16);
  return o + 16;
}

// ---- JSON ------------------------------------------------------------------

size_t lep_to_json(const LepCommand &c, const LedState &cur, char *out,
                   size_t cap) {
  int n = 0;
  uint8_t r, g, b;

  switch (c.opcode) {
  case LEP_OP_POWER:
    n = snprintf(out, cap, "{\"on\":%s,\"tt\":%u}", c.a0 ? "true" : "false",
                 c.a1);
    break;
  case LEP_OP_BRIGHTNESS:
    n = snprintf(out, cap, "{\"bri\":%u,\"tt\":%u}", c.a0, c.a1);
    break;
  case LEP_OP_COLOR:
    rgb_from_565((uint16_t)(c.a0 | c.a1 << 8), &r, &g, &b);
    n = snprintf(out, cap, "{\"seg\":{\"col\":[[%u,%u,%u,%u]]}}", r, g, b,
                 cur.w);
    break;
  case LEP_OP_WHITE:
    n = snprintf(out, cap, "{\"seg\":{\"col\":[[%u,%u,%u,%u]]}}", cur.r, cur.g,
                 cur.b, c.a0);
    break;
  case LEP_OP_CCT:
    n = snprintf(out, cap, "{\"seg\":{\"cct\":%u}}",
                 (unsigned)(c.a0 | c.a1 << 8));
    break;
  case LEP_OP_EFFECT:
    n = snprintf(out, cap, "{\"seg\":{\"fx\":%u,\"sx\":%u}}", c.a0, c.a1);
    break;
  case LEP_OP_EFFECT_ARGS:
    n = snprintf(out, cap, "{\"seg\":{\"ix\":%u,\"c1\":%u}}", c.a0, c.a1);
    break;
  case LEP_OP_PALETTE:
    n = snprintf(out, cap, "{\"seg\":{\"pal\":%u}}", c.a0);
    break;
  case LEP_OP_PRESET:
    if (c.a0 < 1 || c.a0 > 250) return 0;
    n = snprintf(out, cap, "{\"ps\":%u}", c.a0);
    break;
  case LEP_OP_SEGMENT:
    n = snprintf(out, cap, "{\"seg\":{\"id\":%u,\"on\":%s,\"sel\":%s}}", c.a0,
                 (c.a1 & 1) ? "true" : "false",
                 (c.a1 & 2) ? "true" : "false");
    break;
  case LEP_OP_NIGHTLIGHT:
    n = snprintf(out, cap, "{\"nl\":{\"on\":%s,\"dur\":%u,\"mode\":%u}}",
                 (c.a1 & 0x80) ? "true" : "false", c.a0 ? c.a0 : 1,
                 c.a1 & 3);
    break;
  default:
    return 0;
  }
  if (n < 0 || (size_t)n >= cap) return 0;
  return (size_t)n;
}

size_t bthome_command_to_json(uint8_t op, uint8_t arg, char *out,
                              size_t cap) {
  int n;
  unsigned step = (arg ? arg : 1) * 16u;
  if (step > 255) step = 255;

  switch (op) {
  case BTHOME_CMD_OFF: n = snprintf(out, cap, "{\"on\":false}"); break;
  case BTHOME_CMD_ON: n = snprintf(out, cap, "{\"on\":true}"); break;
  case BTHOME_CMD_TOGGLE: n = snprintf(out, cap, "{\"on\":\"t\"}"); break;
  case BTHOME_CMD_STEP_UP:
    n = snprintf(out, cap, "{\"bri\":\"~%u\"}", step);
    break;
  case BTHOME_CMD_STEP_DOWN:
    n = snprintf(out, cap, "{\"bri\":\"~-%u\"}", step);
    break;
  default:
    return 0;
  }
  if (n < 0 || (size_t)n >= cap) return 0;
  return (size_t)n;
}

// ---- helpers ----------------------------------------------------------------

static int hexval(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

bool le_hex_to_key(const char *hex, uint8_t key[16]) {
  int got = 0;
  uint8_t tmp[16];
  int hi = -1;

  for (const char *p = hex; *p; p++) {
    if (*p == ' ' || *p == ':' || *p == '-') continue;
    int v = hexval(*p);
    if (v < 0) return false;
    if (hi < 0) {
      hi = v;
    } else {
      if (got >= 16) return false;
      tmp[got++] = (uint8_t)(hi << 4 | v);
      hi = -1;
    }
  }
  if (got != 16 || hi >= 0) return false;
  memcpy(key, tmp, 16);
  return true;
}

void le_key_to_hex(const uint8_t key[16], char out[33]) {
  static const char d[] = "0123456789abcdef";
  for (int i = 0; i < 16; i++) {
    out[2 * i] = d[key[i] >> 4];
    out[2 * i + 1] = d[key[i] & 15];
  }
  out[32] = 0;
}
