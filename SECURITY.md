# Security

Sill lets an iPhone or iPad see and control a Mac, so a flaw in it matters.
If you find one, please report it privately.

This repository is an unofficial, personal fork of
[Saffsanity/sill](https://github.com/Saffsanity/sill).

## Reporting a problem

- **In the official Sill** (the getsill.app download, the App Store app, or
  code this fork shares with upstream): report it to upstream, as
  [their SECURITY.md](https://github.com/Saffsanity/sill/security/policy) says.
- **In this fork's own changes**: use "Report a vulnerability" on this
  repository's Security tab.

Say what you found, how to reproduce it, and which commit you built. Please
don't open a public issue or pull request for it.

This fork ships no builds, so a fix lands as a commit on `main`; rebuild from
source to get it.

## What is in scope

- The connection on the Mac's own networks, over a USB cable and with Direct
  Wireless Connection: what Sill for Mac accepts, and what a device can make
  it do.
- Remote Access's connection, and pairing, at home and away: the QR code, the
  typed code, `sill://pair` links, a USB cable's automatic pairing, Require
  pairing, and the paired devices and keys Sill for Mac keeps in the keychain.
- The update check, which asks GitHub's releases feed about once a day and
  downloads nothing.

Known, and by design: with Require pairing off (Settings › Devices), any
device on the Mac's own networks, one nearby while Direct Wireless Connection
is on, and any app on the Mac itself connect without pairing, still
encrypted. `SillHost`, the command-line host for development, keeps a plain
home door, with no pairing and no encryption, unless it runs with
`--pairing`. Sill for Mac 0.3.1 and earlier had no pairing and no encryption
at home: update to the newest release.
