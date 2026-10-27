# iDeal LED strip controllers

Le'Casa drives the LED strip controllers sold for the **iDeal LED** app
(Winkison). They show up in Bluetooth as `ISP-xxxxxx` or `IDL-xxxxxx`.
You don't need an account or a key: the app's key is the same in every
controller.

Tested on Chloe's ISP-820ED3 (firmware family TR2309R012) on 2026-10-27.

## What works

- On and off, from the card (tap it) or from the device page.
- Brightness from 1 to 100 %. The controller has no brightness command,
  so Le'Casa scales the colour the same way the vendor app does.
- A set of fixed colours on the device page: warm, white, red, orange,
  green, blue and purple.

## What to know

- The controller never says whether it is on or what colour it shows.
  The card and the device page show what *this screen* last set. A change
  from the vendor app or a remote won't show up. Before the first command
  the card says "Tap to turn on".
- Only one phone or tablet can be connected to the controller at a time.
  Close the iDeal LED app before you use Le'Casa.
- Each command is confirmed by the controller. If no confirmation arrives
  after two tries, Le'Casa reports an error and the card keeps its old state.

## Protocol notes

The controller has a single command characteristic,
`d44bc439-abfd-45a2-b575-925416129600`. You write to it without a
response. Each command is one 16-byte block, encrypted with AES-128-ECB
under a key that is fixed in the app.

The controller answers on `…9601`. Each answer decrypts to the command's
tag followed by `OK`, for example `TURNOK` or `SGLSOK`.

- `TURN 01` / `TURN 00` switches the strip on and off.
- `SGLS` with mode 0 sets a static colour: `0f 'SGLS' 00 00 64 50 r g b r g b 32`.

Le'Casa sends only these two commands, in the exact layouts captured from
the vendor app. The authors of idealLED bricked controllers by sending
made-up commands, such as the calibration and test commands (`CT`,
`TEST`, `LAMPT`, `LAMPN`, `SPLAY`). Don't send those.

The layouts, the key and the test vectors come from
[glowmote](https://github.com/KyleJamesWalker/glowmote) and
[idealLED](https://github.com/8none1/idealLED), both under the MIT licence.
