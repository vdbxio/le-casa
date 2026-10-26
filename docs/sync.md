# Screens and phones (sync)

Le'Casa can run on several tablets and phones in one home. They share what
they read, the keys and PINs you enter, and device controls, over
Bluetooth only. There is no Wi-Fi, no cloud and no account.

The screens form a mesh. None is in charge: each one links to the other
screens it can hear and passes messages along, so a tablet at one end of
the van reaches a phone at the other end through the tablet in between.
Any screen can leave or switch off and the rest carry on.

## Setting it up

1. On any screen, open Settings › Screens and phones › **Start a home** and
   name it.
2. Tap **Add a screen or phone**. That screen takes new ones for three
   minutes. Any screen already in the home can do this, phones included.
3. On the new screen, open Settings › Screens and phones › **Join a home**
   and pick the screen that is adding.
4. Both screens show a six-digit number. If they match, tap **Match** on
   both.

From then on the screens find each other by themselves whenever the app
is open.

## What is shared

- **Readings taken over a connection** (fridge, BMS, stock Xiaomi
  thermometers). One screen at a time reads each of these devices and
  shares what it reads; the others leave it alone. Most of these devices
  take one connection at a time, so this also stops two screens fighting
  over one. Which screen reads it is set per device, on the device's page,
  under **Read by**:
  - **Automatic** (the default): the tablet that hears the device best
    goes first. The others wait 90 seconds for it, then read the device
    themselves if it has not. If the screen reading a device goes quiet for
    three read intervals, another one takes over. Phones only read a device
    when no tablet hears it.
  - **Locked to a screen**: only that screen reads it, phones included.
    Use this when one tablet's Bluetooth does not get along with a device
    (the M10 and the Alpicool fridge, for example).
- **Controls.** Changing the fridge on any screen sends the change to the
  screen that reads the fridge, through other screens if needed.
- **Keys and PINs** (Victron, BTHome, BMS PINs), including removals, and
  the Read by choices. iOS hides MAC addresses, so the same device has a
  different id on an iPad than on an Android tablet; these are matched to
  the other screen's device by MAC when it can, otherwise by the device's
  advertised name.
- **Where each screen is.** Every screen reports how loudly it hears the
  others. Settings › Screens and phones lists, for each screen, which
  screens hear it and at what signal, so you can tell roughly which room a
  phone is in. Automations will use this later.

Broadcast-only devices (Victron, BTHome, pvvx thermometers) are read by
every screen directly.

## How it works

- One Le'Casa GATT service, `4c654361-7361-4c65-8000-000000000000`, run by
  every screen in a home. Characteristics: `…0001` info (read), `…0002`
  chunks to the screen (write with response), `…0003` chunks from it
  (notify). Messages are split into chunks with a one-byte header.
- Each screen advertises a four-byte home tag, the first four bytes of its
  own id, and whether it is adding screens. On Android this goes in
  manufacturer data (id 0xFFFF, starting "LC"); on iOS, which cannot send
  manufacturer data, in the name ("LeCasa 1a2b3c4d.0f1e2d3c", with a "+"
  while adding).
- Links: a screen links to at most four others. When two screens hear each
  other, the one with the smaller id dials; the other dials after 15
  seconds, in case it cannot be heard (a tablet that is not allowed to
  advertise). If both dial at once, they keep the link the smaller id
  opened.
- Every 10 seconds each screen sends a beacon through the mesh: its name,
  the connected devices it hears and how loudly, the screens it hears, and
  its links. Readings, keys, Read by choices and beacons are passed on
  only when they are news to the screen passing them, so nothing goes
  round in circles. Controls go straight to the screen that reads the
  device when linked, otherwise out over every link, and the answer comes
  back the way the control came.
- Pairing is ECDH on P-256. The screen being joined commits to its nonce
  before it sees the newcomer's, so a device in the middle cannot search
  for a matching code. Once both people confirm, it sends the 32-byte home
  key, encrypted with a key derived from the ECDH secret.
- Every later link starts with a hello carrying fresh nonces; both sides
  derive AES-256-GCM keys from the home key and those nonces, one per
  direction, and refuse replayed messages.
- Readings travel with their age rather than a timestamp, so screens with
  clocks that drifted apart (no internet in a van) still agree on what is
  fresh.

Code: `lib/sync/`. Tests: `test/sync/`.

## Known limits

- A screen that may not advertise (Android asks for "Nearby devices"
  permission) can still link to the others, but they cannot link to it.
  Settings › Screens and phones says so when that happens.
- iOS stops advertising when the app goes to the background, so an iPad or
  iPhone needs the app on screen for the others to find it.
- Position is signal strength only: good for "which room", not for
  distances.
- The home key and device keys are kept in the app's normal storage, like
  device keys always were.
