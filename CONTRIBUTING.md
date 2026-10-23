# Contributing to Le'Casa

Thanks for helping. A few rules keep the project shippable:

## Licence agreement

By submitting a contribution you agree that it is licensed under
GPL-3.0-or-later **with the App Store exception** in `LICENSE-EXCEPTION`.
Without that exception the app could not be distributed through Apple's
or Google's stores, so every contributor has to grant it. If you cannot
agree to this, please do not submit code.

You keep your copyright. Add yourself to the copyright line of files you
substantially change if you like.

## Ground rules

- Bluetooth first. Anything that needs Wi-Fi, a router, a Pi or a cloud
  account is out of scope unless it is strictly optional.
- No login, ever. No accounts, no telemetry, no phone-home.
- Zero-setup detection: a device should be recognised from its broadcast
  and offered to the user, not configured by hand. Encryption keys are the
  one thing we cannot avoid asking for.
- Decoders are pure Dart over `RawAdvertisement` and come with a test
  using a real captured packet. If you add a device, add its packet.
- Third-party code and formats go in `NOTICE.md` with their licence.
  Apache-2.0, MIT and BSD are fine inside GPL; anything that is not
  GPL-compatible is not.

## Dev loop

```sh
flutter pub get
flutter analyze
flutter test
flutter run            # with an Android tablet or iPad plugged in
```

CI runs analyze + test and builds a debug APK you can download from the
workflow run.
