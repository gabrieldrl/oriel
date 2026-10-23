# Oriel

Your Mac's windows, on your iPhone and iPad.

Oriel streams any window from your Mac, or the whole desktop, to your iPhone or iPad, and sends
your touches, trackpad and keys back. The Mac and the device connect directly, over your Wi‑Fi, a
USB cable or your own VPN such as Tailscale. There's no account, no server and no subscription.

## Requirements

- A Mac with Apple silicon, on macOS 27 or later
- An iPhone or iPad on iOS 27 or later

## Install

**Mac:** download `Oriel.dmg` from [Releases](https://github.com/gabrieldrl/oriel/releases/latest)
and drag Oriel to Applications. It isn't notarized yet, so the first time it's blocked: open
System Settings › Privacy & Security and click Open Anyway.

**iPhone and iPad:** build it from source (below).

## Build from source

Mac app:

```
Scripts/make-app.sh --install --open
```

iPhone and iPad app: open `iOSClient/Sill.xcodeproj`, pick your team and a bundle ID of your own,
and run it on your device.

[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) has everything else.

## Credits

Oriel is built on [Sill](https://github.com/Saffsanity/sill) by Noah Saffer. It isn't affiliated
with or endorsed by the Sill project.

## License

[Apache License 2.0](LICENSE). Copyright 2026 Noah Saffer; modifications copyright 2026 Gabriel Lam.
