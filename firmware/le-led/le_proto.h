// Le'Proto v0: connectionless two-way Bluetooth LE framing for Le'devices.
//
// Pure C++ with no Arduino, WLED or NimBLE dependency, so the host tests in
// tests/ exercise exactly the code that runs on the ESP32. The only thing the
// platform supplies is one AES-128 block encryption (hardware AES on the
// ESP32, OpenSSL in the tests), set once with le_set_aes().
//
// What lives here:
//   - AES-CCM (4-byte MIC, 13-byte nonce, optional AAD)
//   - BTHome v2 encryption: build Le'LED's encrypted state advert, and
//     decrypt other devices' encrypted BTHome adverts (Le'Fob buttons)
//   - the Le'Proto 16-byte compact command frame: seal (tablet side, used by
//     tests and tools) and open (light side) with replay protection
//   - opcode -> WLED JSON translation
//
// The wire format is specified in PROTOCOL.md next to this file.
//
// SPDX-License-Identifier: EUPL-1.2

#ifndef LE_PROTO_H
#define LE_PROTO_H

#include <stddef.h>
#include <stdint.h>

// ---- AES ---------------------------------------------------------------

typedef void (*le_aes_fn)(const uint8_t key[16], const uint8_t in[16],
                          uint8_t out[16]);
void le_set_aes(le_aes_fn fn);
void le_aes(const uint8_t key[16], const uint8_t in[16], uint8_t out[16]);

// ---- AES-CCM (M = 4, L = 2) ---------------------------------------------

#define LE_CCM_NONCE_LEN 13
#define LE_CCM_MIC_LEN 4

void le_ccm_encrypt(const uint8_t key[16], const uint8_t nonce[13],
                    const uint8_t *aad, size_t aad_len, uint8_t *buf,
                    size_t len, uint8_t mic[4]);
bool le_ccm_decrypt(const uint8_t key[16], const uint8_t nonce[13],
                    const uint8_t *aad, size_t aad_len, uint8_t *buf,
                    size_t len, const uint8_t mic[4]);

// ---- BTHome v2 -----------------------------------------------------------

#define BTHOME_UUID 0xFCD2
#define BTHOME_INFO_ENCRYPTED 0x01
#define BTHOME_INFO_TRIGGER 0x04
#define BTHOME_INFO_V2 0x40

#define BTHOME_OBJ_PACKET_ID 0x00
#define BTHOME_OBJ_POWER 0x10   // binary: 1 = on
#define BTHOME_OBJ_BUTTON 0x3A  // event
#define BTHOME_OBJ_COMMAND 0x3B // [len][opcode][args...]
#define BTHOME_OBJ_RAW 0x54     // [len][bytes...]

#define BTHOME_EVT_PRESS 0x01
#define BTHOME_EVT_DOUBLE_PRESS 0x02
#define BTHOME_EVT_LONG_PRESS 0x04
#define BTHOME_EVT_HOLD_PRESS 0x80

#define BTHOME_CMD_OFF 0x00
#define BTHOME_CMD_ON 0x01
#define BTHOME_CMD_TOGGLE 0x02
#define BTHOME_CMD_STEP_UP 0x03
#define BTHOME_CMD_STEP_DOWN 0x04

// The address in "display" order (most significant byte first), as BTHome
// puts it in the nonce. Over the air the order is reversed.
void bthome_nonce(uint8_t nonce[13], const uint8_t mac_msb_first[6],
                  uint8_t info, uint32_t counter);

// Find the BTHome service data in an advertising payload (a list of AD
// structures). Returns the length of the bytes after the UUID (device info
// byte onwards) and points *out at them, or 0 if there is none.
size_t bthome_find(const uint8_t *adv, size_t adv_len, const uint8_t **out);

// Decrypt a BTHome v2 service-data body (device info byte onwards) in
// place into plain[]. Returns the number of plaintext object bytes, or -1 if
// it is not encrypted, too short, or the MIC does not verify.
int bthome_decrypt(const uint8_t key[16], const uint8_t mac_msb_first[6],
                   const uint8_t *body, size_t body_len, uint8_t *plain,
                   uint32_t *counter_out);

// What a BTHome remote asked for, pulled out of decrypted objects.
struct BthomeEvents {
  bool has_packet_id;
  uint8_t packet_id;
  uint8_t buttons;        // number of 0x3A objects seen (max 8)
  uint8_t button[8];      // their events in order (0 = none)
  bool has_command;
  uint8_t command;        // 0x3B opcode
  uint8_t command_arg;    // first argument, 0 if none
};
// Walk plaintext objects. Stops quietly at the first object id it does not
// know the size of (as the BTHome spec tells receivers to).
void bthome_parse_events(const uint8_t *objs, size_t len, BthomeEvents *ev);

// ---- Le'LED state ----------------------------------------------------------

struct LedState {
  bool on;
  uint8_t bri;
  uint8_t r, g, b, w;
  uint8_t fx, pal, sx, ix;
  uint8_t preset;
};

#define LE_STATE_RAW_LEN 10 // bytes inside the 0x54 raw object
// First byte of the scan response's manufacturer data (0xFFFF) that
// carries the MAC, so it never looks like a Le'Proto frame (0x4C).
#define LE_SCAN_MAC_MARK 0x4D

uint16_t rgb_to_565(uint8_t r, uint8_t g, uint8_t b);
void rgb_from_565(uint16_t v, uint8_t *r, uint8_t *g, uint8_t *b);

// The 10 raw bytes: rev, ack, bri, rgb565 LE, fx, pal, sx, ix, preset.
void le_state_pack(const LedState &s, uint8_t rev, uint8_t ack,
                   uint8_t out[LE_STATE_RAW_LEN]);

// Build Le'LED's whole advertising payload (flags + encrypted BTHome service
// data). `mac` is the light's own address, most significant byte first.
// Returns its length (30), which always fits a legacy advert.
size_t le_build_state_adv(const uint8_t key[16], const uint8_t mac[6],
                          uint32_t counter, const LedState &s, uint8_t rev,
                          uint8_t ack, uint8_t out[31]);

// ---- Le'Proto compact frame -----------------------------------------------

#define LEP_FRAME_LEN 16
#define LEP_MAGIC 0x4C // 'L'
#define LEP_TYPE_COMMAND 0x1
#define LEP_FLAG_ACK_REQ 0x10
#define LEP_FLAG_GROUP 0x20
#define LEP_SLOTS 4
#define LEP_MFR_ID 0xFFFF // prototype company id, see PROTOCOL.md

enum LepOpcode : uint8_t {
  LEP_OP_POWER = 0x01,      // a0 0 off / 1 on, a1 transition (100 ms)
  LEP_OP_BRIGHTNESS = 0x02, // a0 0..255, a1 transition
  LEP_OP_COLOR = 0x03,      // a0 a1 = RGB565, little-endian
  LEP_OP_WHITE = 0x04,      // a0 white 0..255
  LEP_OP_CCT = 0x05,        // a0 a1 = Kelvin, little-endian
  LEP_OP_EFFECT = 0x06,     // a0 effect id, a1 speed
  LEP_OP_EFFECT_ARGS = 0x07,// a0 intensity, a1 custom 1
  LEP_OP_PALETTE = 0x08,    // a0 palette id
  LEP_OP_PRESET = 0x09,     // a0 preset id 1..250
  LEP_OP_SEGMENT = 0x0A,    // a0 segment id, a1 bit0 on, bit1 selected
  LEP_OP_NIGHTLIGHT = 0x0B, // a0 minutes, a1 bit7 on, bits0-1 mode
  LEP_OP_WAKE = 0x0C,       // a0 seconds of fast advertising
};

struct LepKeys {
  uint8_t key[16];  // the device key; also its BTHome bindkey
  uint8_t down[16]; // AES(key, "LeProto-down-v0\0"), commands to the device
  uint8_t dst[3];   // AES(key, "LeProto-dstid-v0")[0..2], its address
};
void lep_derive(const uint8_t key[16], LepKeys *k);

struct LepCommand {
  uint8_t slot;     // source slot 0..3
  uint32_t seq;     // 24 bits
  uint8_t flags;    // LEP_FLAG_*
  uint8_t opcode;
  uint8_t a0, a1;
};

// Tablet side: fill a 16-byte frame.
void lep_seal(const LepKeys &k, const LepCommand &c, uint8_t out[16]);

// Light side. `last_seq` holds the highest accepted seq per slot (0 means
// none yet; senders start at 1). On success it is advanced and true is
// returned. Wrong magic, wrong destination, bad MIC and replays all return
// false and leave last_seq alone.
enum LepResult { LEP_OK = 0, LEP_NOT_OURS, LEP_BAD_MIC, LEP_REPLAY };
LepResult lep_open(const LepKeys &k, const uint8_t frame[16],
                   uint32_t last_seq[LEP_SLOTS], LepCommand *out);

// Find a Le'Proto frame in an advertising payload: manufacturer data with
// company id 0xFFFF followed by 16 bytes starting with the magic (Android,
// ESP32), or a 128-bit service UUID whose on-air first byte is the magic
// (iOS). Returns true and copies the 16 bytes on a hit.
bool lep_find(const uint8_t *adv, size_t adv_len, uint8_t frame[16]);

// Build a Le'Proto advert for the tools and tests: flags + manufacturer data.
size_t lep_build_mfr_adv(const uint8_t frame[16], uint8_t out[31]);

// Ack byte carried in the state advert: slot in bits 6-7, low 6 bits of seq.
inline uint8_t lep_ack_byte(uint8_t slot, uint32_t seq) {
  return (uint8_t)(((slot & 3) << 6) | (seq & 0x3F));
}

// ---- JSON ------------------------------------------------------------------

// Turn a command into WLED JSON API text. `cur` is the light's state now
// (the white opcode keeps the current colour, the colour opcode keeps the
// current white). Returns the length written, or 0 for opcodes that are not
// state changes (wake) or are unknown.
size_t lep_to_json(const LepCommand &c, const LedState &cur, char *out,
                   size_t cap);

// The same for a BTHome 0x3B command from a plain BTHome remote.
size_t bthome_command_to_json(uint8_t opcode, uint8_t arg, char *out,
                              size_t cap);

// ---- helpers ----------------------------------------------------------------

bool le_hex_to_key(const char *hex, uint8_t key[16]);
void le_key_to_hex(const uint8_t key[16], char out[33]);

#endif
