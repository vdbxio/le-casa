# Screens and phones (sync)

Le'Casa can run on several tablets and phones in one home. They share what
they read, the keys and PINs you enter, and device controls, over
Bluetooth only. There is no Wi-Fi, no cloud and no account.

## Setting it up

1. On the screen with the best Bluetooth that stays on, open
   Settings › Screens and phones › **Make this screen the hub** and name the
   home.
2. Tap **Add a screen or phone**. The hub takes new screens for three
   minutes.
3. On the other screen, open Settings › Screens and phones › **Join a hub**
   and pick the hub.
4. Both screens show a six-digit number. If they match, tap **Match** on
   both.

From then on the screens find each other by themselves whenever the app
is open.

## What is shared

- **Readings taken over a connection** (fridge, BMS, stock Xiaomi
  thermometers). Whichever screen reads a device shares the reading, and
  the other screens stop connecting to it. Most of these devices take one
  connection at a time, so this also stops two screens fighting over one.
  If the screen that holds a device goes quiet for three read intervals,
  another one takes over.
- **Controls.** Changing the fridge on any screen sends the change to the
  screen that holds the fridge's connection.
- **Keys and PINs** (Victron, BTHome, BMS PINs), including removals. iOS
  hides MAC addresses, so the same device has a different id on an iPad
  than on an Android tablet; a key is matched to the other screen's device
  by MAC when it can, otherwise by the device's advertised name.

Broadcast-only devices (Victron, BTHome, pvvx thermometers) are read by
every screen directly.

## How it works

- One Le'Casa GATT service, `4c654361-7361-4c65-8000-000000000000`, run by
  the hub. Members connect to it as clients. Characteristics: `…0001` info
  (read), `…0002` member to hub (write with response), `…0003` hub to
  member (notify). Messages are split into chunks with a one-byte header.
- The hub advertises a four-byte home tag so members pick their own hub
  among the neighbours': in manufacturer data (id 0xFFFF) on Android, in
  the name ("LeCasa 1a2b3c4d") on iOS, which cannot send manufacturer data.
- Pairing is ECDH on P-256. The hub commits to its nonce before it sees
  the member's, so a device in the middle cannot search for a matching
  code. Once both people confirm, the hub sends the 32-byte home key,
  encrypted with a key derived from the ECDH secret.
- Every later link starts with a hello carrying fresh nonces; both sides
  derive AES-256-GCM keys from the home key and those nonces, one per
  direction, and refuse replayed messages.
- Readings travel with their age rather than a timestamp, so screens with
  clocks that drifted apart (no internet in a van) still agree on what is
  fresh.

Code: `lib/sync/`. Tests: `test/sync/`.

## Known limits

- Every screen has to be in Bluetooth range of the hub. The hub passes
  messages between members; members do not relay for each other yet.
- iOS stops advertising when the app goes to the background, so an iPad or
  iPhone hub needs the app on screen.
- The home key and device keys are kept in the app's normal storage, like
  device keys always were.
