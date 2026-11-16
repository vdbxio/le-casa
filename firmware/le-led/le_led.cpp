// Le'LED: a WLED usermod that speaks Le'Proto over Bluetooth LE.
//
//   - Broadcasts the light's state as encrypted BTHome v2 (power + a raw
//     state object), so every Le'Casa screen and Home Assistant hear it at
//     once with no connection.
//   - Scans all the time for Le'Proto command frames (manufacturer data from
//     Android/ESP32, or a 128-bit service UUID from iOS) addressed to it.
//   - Takes encrypted BTHome button presses from Le'Fobs whose keys it knows,
//     and plain BTHome 0x3B commands from those fobs too.
//
// Everything that touches bytes lives in le_proto.cpp and is host-tested; this
// file is the WLED and NimBLE glue. See README.md and PROTOCOL.md.
//
// SPDX-License-Identifier: EUPL-1.2

#include "wled.h"

#include <NimBLEDevice.h>
#include <Preferences.h>
#include <freertos/queue.h>
#include <mbedtls/aes.h>

#include "le_proto.h"

#ifndef LELED_STATUS_PIN
#define LELED_STATUS_PIN -1 // a plain LED that blinks on every accepted command
#endif
#ifndef LELED_BT_ONLY
#define LELED_BT_ONLY true // keep the Wi-Fi AP closed unless the button asks
#endif

#define LELED_FOBS 4
#define LELED_IDLE_INTERVAL_MS 1000
#define LELED_FAST_INTERVAL_MS 30
#define LELED_FAST_FOR_MS 2000
#define LELED_COUNTER_RESERVE 4096
#define LELED_JSON_LOCK 76

static void hw_aes(const uint8_t key[16], const uint8_t in[16],
                   uint8_t out[16]) {
  mbedtls_aes_context ctx;
  mbedtls_aes_init(&ctx);
  mbedtls_aes_setkey_enc(&ctx, key, 128);
  mbedtls_aes_crypt_ecb(&ctx, MBEDTLS_AES_ENCRYPT, in, out);
  mbedtls_aes_free(&ctx);
}

// One received advert, handed from the NimBLE task to WLED's loop.
struct RxAdv {
  uint8_t mac[6]; // most significant byte first
  int8_t rssi;
  uint8_t len;
  uint8_t data[31];
};

static QueueHandle_t g_rx = nullptr;

class LeLedScanCallbacks : public NimBLEAdvertisedDeviceCallbacks {
  void onResult(NimBLEAdvertisedDevice *d) override {
    size_t len = d->getPayloadLength();
    if (!g_rx || len == 0 || len > 31) return;
    const uint8_t *p = d->getPayload();

    // Cheap filter here; crypto happens in loop(). Keep Le'Proto frames and
    // encrypted BTHome (possible fob presses).
    uint8_t frame[16];
    const uint8_t *bt = nullptr;
    bool want = lep_find(p, len, frame);
    if (!want) {
      size_t bl = bthome_find(p, len, &bt);
      want = bl > 0 && (bt[0] & BTHOME_INFO_ENCRYPTED);
    }
    if (!want) return;

    RxAdv rx;
    const uint8_t *a = d->getAddress().getNative(); // least significant first
    for (int i = 0; i < 6; i++) rx.mac[i] = a[5 - i];
    rx.rssi = (int8_t)d->getRSSI();
    rx.len = (uint8_t)len;
    memcpy(rx.data, p, len);
    xQueueSend(g_rx, &rx, 0);
  }
};

class LeLedUsermod : public Usermod {
 private:
  bool enabled = true;
  bool btOnly = LELED_BT_ONLY;
  bool initDone = false;
  bool bleUp = false;
  int8_t statusPin = LELED_STATUS_PIN;

  String keyHex;
  LepKeys keys;
  bool keyOk = false;
  uint8_t ownMac[6];

  // Le'Fobs (or any encrypted BTHome remote).
  String fobKeyHex[LELED_FOBS];
  uint8_t fobKey[LELED_FOBS][16];
  bool fobKeyOk[LELED_FOBS] = {false, false, false, false};
  uint8_t fobMac[LELED_FOBS][6];
  bool fobMacKnown[LELED_FOBS] = {false, false, false, false};
  uint32_t fobLastCounter[LELED_FOBS] = {0, 0, 0, 0};
  int16_t fobLastPid[LELED_FOBS] = {-1, -1, -1, -1};
  unsigned long fobLastSeen[LELED_FOBS] = {0, 0, 0, 0};
  String press[LELED_FOBS];
  String longPress[LELED_FOBS];

  // Le'Proto replay windows, one per source slot. RAM only in v0 (see README).
  uint32_t lastSeq[LEP_SLOTS] = {0, 0, 0, 0};
  uint8_t ack = 0;

  // Uplink.
  Preferences prefs;
  uint32_t counter = 0, counterReserved = 0;
  uint8_t rev = 0;
  uint8_t lastRaw[2 + LE_STATE_RAW_LEN];
  bool haveLast = false;
  unsigned long fastUntil = 0;
  bool fastNow = false;
  unsigned long lastPoll = 0;

  // Stats for the info page.
  uint32_t accepted = 0, rejected = 0, fobPresses = 0;
  int8_t lastRssi = 0;
  unsigned long ledOffAt = 0;

  static const char _name[];

  // ---- helpers -------------------------------------------------------------

  LedState readState() {
    LedState s;
    Segment &seg = strip.getMainSegment();
    uint32_t c = seg.colors[0];
    s.on = bri > 0;
    s.bri = s.on ? bri : briLast;
    s.w = (c >> 24) & 0xFF;
    s.r = (c >> 16) & 0xFF;
    s.g = (c >> 8) & 0xFF;
    s.b = c & 0xFF;
    s.fx = seg.mode;
    s.pal = seg.palette;
    s.sx = seg.speed;
    s.ix = seg.intensity;
    s.preset = currentPreset;
    return s;
  }

  bool applyJson(const char *json, byte callMode) {
    if (!requestJSONBufferLock(LELED_JSON_LOCK)) return false;
    DeserializationError err = deserializeJson(*pDoc, json);
    bool ok = !err;
    if (ok) deserializeState(pDoc->as<JsonObject>(), callMode);
    releaseJSONBufferLock();
    return ok;
  }

  void blink() {
    if (statusPin < 0) return;
    digitalWrite(statusPin, HIGH);
    ledOffAt = millis() + 40;
  }

  void loadKeys() {
    keyOk = le_hex_to_key(keyHex.c_str(), keys.key);
    if (!keyOk) {
      // First boot, or the key was cleared: make one. The radio is on by
      // now, so esp_fill_random draws on true RF noise.
      esp_fill_random(keys.key, 16);
      char hex[33];
      le_key_to_hex(keys.key, hex);
      keyHex = hex;
      keyOk = true;
      configNeedsWrite = true;
    }
    lep_derive(keys.key, &keys);
    for (int i = 0; i < LELED_FOBS; i++) {
      fobKeyOk[i] = fobKeyHex[i].length() &&
                    le_hex_to_key(fobKeyHex[i].c_str(), fobKey[i]);
      if (!fobKeyOk[i]) fobMacKnown[i] = false;
    }
  }

  uint32_t nextCounter() {
    counter++;
    if (counter >= counterReserved) {
      // Reserve the next block before using it, so a reboot never repeats
      // a counter that already went out.
      counterReserved = counter + LELED_COUNTER_RESERVE;
      prefs.putULong("ctr", counterReserved);
    }
    return counter;
  }

  void setInterval(bool fast) {
    if (!bleUp) return;
    NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
    uint16_t units = (uint16_t)((fast ? LELED_FAST_INTERVAL_MS
                                      : LELED_IDLE_INTERVAL_MS) * 1000 / 625);
    adv->stop();
    adv->setMinInterval(units);
    adv->setMaxInterval(units + (fast ? 8 : 80));
    adv->start();
    fastNow = fast;
  }

  void burst(unsigned long ms) {
    fastUntil = millis() + ms;
    if (!fastNow) setInterval(true);
  }

  // Rebuild the advert if the state changed (or force it).
  void publish(bool force) {
    if (!bleUp || !keyOk) return;
    LedState s = readState();
    uint8_t raw[2 + LE_STATE_RAW_LEN];
    raw[0] = s.on;
    raw[1] = ack;
    le_state_pack(s, 0, 0, raw + 2); // rev and ack left out of the compare
    if (!force && haveLast && memcmp(raw, lastRaw, sizeof raw) == 0) return;
    memcpy(lastRaw, raw, sizeof raw);
    haveLast = true;
    rev++;

    uint8_t adv[31];
    size_t n = le_build_state_adv(keys.key, ownMac, nextCounter(), s, rev, ack,
                                  adv);
    NimBLEAdvertisementData data;
    data.addData((char *)adv, n);
    NimBLEDevice::getAdvertising()->setAdvertisementData(data);
    burst(LELED_FAST_FOR_MS);
  }

  void startBle() {
    NimBLEDevice::init("");
    NimBLEDevice::setPower(ESP_PWR_LVL_P9);
    const uint8_t *a = NimBLEDevice::getAddress().getNative();
    for (int i = 0; i < 6; i++) ownMac[i] = a[5 - i];

    // Scan response carries the name, so the main advert keeps its room.
    char name[16];
    snprintf(name, sizeof name, "LeLED-%02X%02X", ownMac[4], ownMac[5]);
    NimBLEAdvertisementData rsp;
    rsp.setName(name);
    NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
    adv->setAdvertisementType(BLE_GAP_CONN_MODE_NON);
    adv->setScanResponse(true);
    adv->setScanResponseData(rsp);

    g_rx = xQueueCreate(16, sizeof(RxAdv));
    NimBLEScan *scan = NimBLEDevice::getScan();
    scan->setAdvertisedDeviceCallbacks(new LeLedScanCallbacks(), true);
    scan->setActiveScan(false);
    scan->setDuplicateFilter(false); // a tablet repeats with new bytes
    scan->setMaxResults(0);          // callbacks only, keep no list
    scan->setInterval(40);
    scan->setWindow(40); // 100% duty; the controller shares with Wi-Fi
    scan->start(0, nullptr, false);

    bleUp = true;
    publish(true);
  }

  // ---- receive -------------------------------------------------------------

  void handleCommand(const LepCommand &c) {
    accepted++;
    ack = lep_ack_byte(c.slot, c.seq);
    blink();
    if (c.opcode == LEP_OP_WAKE) {
      burst((c.a0 ? c.a0 : 2) * 1000UL);
      publish(true);
      return;
    }
    char json[96];
    if (lep_to_json(c, readState(), json, sizeof json)) {
      applyJson(json, CALL_MODE_DIRECT_CHANGE);
    }
    publish(true); // even with no change, so the sender sees its ack
  }

  int findFob(const uint8_t mac[6], const uint8_t *body, size_t bl,
              uint8_t *plain, uint32_t *ctr, int *plen) {
    // Known address first, then try each key on fobs we have not placed yet.
    for (int i = 0; i < LELED_FOBS; i++) {
      if (fobKeyOk[i] && fobMacKnown[i] && memcmp(fobMac[i], mac, 6) == 0) {
        *plen = bthome_decrypt(fobKey[i], mac, body, bl, plain, ctr);
        return *plen >= 0 ? i : -1;
      }
    }
    for (int i = 0; i < LELED_FOBS; i++) {
      if (!fobKeyOk[i] || fobMacKnown[i]) continue;
      *plen = bthome_decrypt(fobKey[i], mac, body, bl, plain, ctr);
      if (*plen >= 0) {
        memcpy(fobMac[i], mac, 6);
        fobMacKnown[i] = true;
        return i;
      }
    }
    return -1;
  }

  void handleBthome(const RxAdv &rx, const uint8_t *body, size_t bl) {
    uint8_t plain[32];
    uint32_t ctr = 0;
    int plen = -1;
    if (bl > sizeof(plain) + 9) return;
    int i = findFob(rx.mac, body, bl, plain, &ctr, &plen);
    if (i < 0) return;
    fobLastSeen[i] = millis();

    // Replay guard: the counter must climb. Each advertising round of the
    // fob carries a fresh counter, so this also drops repeats of a round.
    if (ctr <= fobLastCounter[i]) return;
    fobLastCounter[i] = ctr;

    BthomeEvents ev;
    bthome_parse_events(plain, (size_t)plen, &ev);
    // A press goes out as a burst of rounds sharing one packet id.
    if (ev.has_packet_id) {
      if (ev.packet_id == fobLastPid[i]) return;
      fobLastPid[i] = ev.packet_id;
    }

    if (ev.has_command) {
      char json[48];
      if (bthome_command_to_json(ev.command, ev.command_arg, json,
                                 sizeof json)) {
        fobPresses++;
        blink();
        applyJson(json, CALL_MODE_BUTTON);
      }
    }
    for (int b = 0; b < ev.buttons && b < LELED_FOBS; b++) {
      const String *action = nullptr;
      if (ev.button[b] == BTHOME_EVT_PRESS) action = &press[b];
      else if (ev.button[b] == BTHOME_EVT_LONG_PRESS) action = &longPress[b];
      if (action && action->length()) {
        fobPresses++;
        blink();
        applyJson(action->c_str(), CALL_MODE_BUTTON);
      }
    }
  }

  void handleRx(const RxAdv &rx) {
    lastRssi = rx.rssi;
    uint8_t frame[16];
    if (lep_find(rx.data, rx.len, frame)) {
      LepCommand c;
      LepResult r = lep_open(keys, frame, lastSeq, &c);
      if (r == LEP_OK) handleCommand(c);
      else if (r != LEP_NOT_OURS) rejected++;
      return;
    }
    const uint8_t *body = nullptr;
    size_t bl = bthome_find(rx.data, rx.len, &body);
    if (bl) handleBthome(rx, body, bl);
  }

 public:
  LeLedUsermod() {
    press[0] = F("{\"on\":\"t\"}");
    press[1] = F("{\"bri\":\"~32\"}");
    press[2] = F("{\"bri\":\"~-32\"}");
    press[3] = F("{\"ps\":\"1~16~\"}");
    longPress[0] = F("{\"on\":false}");
    longPress[1] = F("{\"bri\":255}");
    longPress[2] = F("{\"bri\":16}");
    longPress[3] = F("{\"ps\":1}");
  }

  void setup() override {
    le_set_aes(hw_aes);
    if (!enabled) return;

    if (btOnly) apBehavior = AP_BEHAVIOR_BUTTON_ONLY;

    if (statusPin >= 0 &&
        PinManager::allocatePin(statusPin, true, PinOwner::UM_Unspecified)) {
      pinMode(statusPin, OUTPUT);
      digitalWrite(statusPin, LOW);
    } else {
      statusPin = -1;
    }

    prefs.begin("leled", false);
    counter = prefs.getULong("ctr", 0);
    counterReserved = counter; // forces a fresh reservation on first use

    loadKeys();
    char hex[33];
    le_key_to_hex(keys.key, hex);
    Serial.printf("Le'LED key %s, Le'Proto id %02x%02x%02x\n", hex,
                  keys.dst[0], keys.dst[1], keys.dst[2]);

    startBle();
    initDone = true;
  }

  void loop() override {
    if (!enabled || !initDone) return;

    RxAdv rx;
    int budget = 8;
    while (budget-- && xQueueReceive(g_rx, &rx, 0) == pdTRUE) handleRx(rx);

    unsigned long now = millis();
    if (now - lastPoll > 50) {
      lastPoll = now;
      publish(false);
    }
    if (fastNow && (long)(now - fastUntil) > 0) setInterval(false);
    if (ledOffAt && (long)(now - ledOffAt) > 0) {
      digitalWrite(statusPin, LOW);
      ledOffAt = 0;
    }
  }

  void addToJsonInfo(JsonObject &root) override {
    JsonObject user = root["u"];
    if (user.isNull()) user = root.createNestedObject("u");
    JsonArray a = user.createNestedArray(F("Le'LED commands"));
    a.add(accepted);
    a.add(rejected ? String(F(" ok, ")) + rejected + F(" refused")
                   : String(F(" ok")));
    JsonArray f = user.createNestedArray(F("Le'LED fob presses"));
    f.add(fobPresses);
    char id[12];
    snprintf(id, sizeof id, "%02x%02x%02x", keys.dst[0], keys.dst[1],
             keys.dst[2]);
    JsonArray d = user.createNestedArray(F("Le'Proto id"));
    d.add(id);
  }

  void addToConfig(JsonObject &root) override {
    JsonObject top = root.createNestedObject(FPSTR(_name));
    top[F("enabled")] = enabled;
    top[F("btOnly")] = btOnly;
    top[F("key")] = keyHex;
    top[F("statusPin")] = statusPin;
    for (int i = 0; i < LELED_FOBS; i++) {
      char k[8];
      snprintf(k, sizeof k, "fob%d", i + 1);
      top[k] = fobKeyHex[i];
      snprintf(k, sizeof k, "b%d", i + 1);
      top[k] = press[i];
      snprintf(k, sizeof k, "b%dlong", i + 1);
      top[k] = longPress[i];
    }
  }

  bool readFromConfig(JsonObject &root) override {
    JsonObject top = root[FPSTR(_name)];
    if (top.isNull()) return false;
    getJsonValue(top[F("enabled")], enabled);
    getJsonValue(top[F("btOnly")], btOnly);
    getJsonValue(top[F("key")], keyHex);
    getJsonValue(top[F("statusPin")], statusPin);
    for (int i = 0; i < LELED_FOBS; i++) {
      char k[8];
      snprintf(k, sizeof k, "fob%d", i + 1);
      getJsonValue(top[k], fobKeyHex[i]);
      snprintf(k, sizeof k, "b%d", i + 1);
      getJsonValue(top[k], press[i]);
      snprintf(k, sizeof k, "b%dlong", i + 1);
      getJsonValue(top[k], longPress[i]);
    }
    if (initDone) loadKeys(); // edited from the settings page
    return true;
  }

  void appendConfigData(Print &s) override {
    s.print(F("addInfo('LeLED:btOnly',1,'keep Wi-Fi off; leave the Wi-Fi network empty');"));
    s.print(F("addInfo('LeLED:key',1,'32 hex. Enter it in Le\\'Casa. Empty = make a new one');"));
    s.print(F("addInfo('LeLED:fob1',1,'Le\\'Fob key (hold SW2 5 s on USB to type it here)');"));
    s.print(F("addInfo('LeLED:b1',1,'WLED JSON for button 1 press');"));
  }

  uint16_t getId() override { return USERMOD_ID_UNSPECIFIED; }
};

const char LeLedUsermod::_name[] PROGMEM = "LeLED";

static LeLedUsermod le_led;
REGISTER_USERMOD(le_led);
