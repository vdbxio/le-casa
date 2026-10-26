# Tablets and phones we have tested

What each screen's Bluetooth can and cannot do, measured on real
hardware. Use it to decide which screen should read which device (each
device page has a **Read by** choice).

## PRITOM M10 (Android 14, about $50)

Allwinner A133 with an AIC8800DC Wi-Fi + Bluetooth combo chip on SDIO
(one radio and antenna shared by Wi-Fi and Bluetooth).

Works well:

- Scanning: hears every broadcast device reliably (Victron, BTHome,
  pvvx and stock Xiaomi with a bindkey, Le'Casa screens).
- Advertising and serving the Le'Casa screen service, and linking to
  other screens. Extended advertising is supported.
- Short connections to Xiaomi thermometers, with retries (about a third
  of connects fail with status 133 first).

Does not work, or not reliably:

- **Daly BMS:** every link drops with status 8 about 4 s after the module
  asks for new connection parameters, before any reply. Nothing in the
  app changes this. Lock the Daly to another screen.
- **Alpicool fridge:** cannot hold the connection. Lock it to another
  screen.
- **More than two links:** it holds two links (for example the iPad and
  an iPhone) while scanning, but a third connect fails with status 133
  every time. In a 20-minute run (2026-10-26) with both links up, all 3
  of its device polls (two Xiaomis and the fridge) failed this way. Read
  devices from their broadcasts where possible (a bindkey for stock
  Xiaomi firmware), or lock them to another screen.
- **Several Bluetooth jobs at once:** the chip's firmware can stop
  answering. Seen twice (2026-10-26) when the scan was paused for a
  connect while a write to another screen was stuck: Android logged
  "Timed out waiting for 0xfd57 (LE_ADV_FILTER)", aborted its Bluetooth
  service, and the chip stayed wedged until a reboot. Since then Le'Casa
  waits for writes in flight before pausing the scan, and leaves the
  scan running if any are still waiting.
- Wireless debugging drops now and then, and switches off on every
  reboot (Wi-Fi shares the radio). A "Wireless debugging" quick-settings
  tile (Developer options › Quick settings developer tiles) turns it back
  on in one tap.

Suggested use: a display that reads broadcasts and short connections,
with connection-heavy devices locked to an iPad or a better tablet.

## iPad Pro 11 (2nd gen, iPadOS 27)

Holds several links at once. Reads the Daly over a link it keeps open,
every 4 s, while still polling the fridge and Xiaomis. Seen issues, all
handled in the app: a Bluetooth call that never returns (now bounded),
a dropped link the system never reports (now replaced on reconnect).
iOS hides MAC addresses and stops advertising in the background, so keep
the app on screen.

## iPhone

Joins as a phone: reads a device only when it is locked to it or no
tablet hears it. Same iOS limits as the iPad.
