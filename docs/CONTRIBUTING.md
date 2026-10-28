# Contributing

Thanks for wanting to make Starlight better. Bug reports, fixes and ideas are all welcome.

## Before you start

- **Bugs:** open an issue with what you did, what you expected, what happened, your Mac and
  macOS version. `~/Library/Logs/Starlight.log` from a dev build helps.
- **Features:** open an issue first, so we can agree on the shape before you spend time on it.
  Starlight stays small on purpose; not every good idea fits.
- **Security problems:** don't open an issue. See [SECURITY.md](SECURITY.md).

## Building

```bash
./build.sh && open Starlight.app
```

The first build downloads llama.cpp (checksum-verified) into `Vendor/`. You need Xcode's command
line tools and a Mac with Apple silicon.

## Pull requests

- One change per pull request, with a sentence on why.
- Match the code around you: its naming, its comment style, and the design rules in the style
  guide (black and white only, springs not curves, one thing at a time in the notch).
- If it changes what the notch shows, include a screenshot.
- Run `./build.sh` before you send it; it must build without new warnings.

## Your contribution's license

Starlight is released under the [GNU General Public License v3.0](../LICENSE). By sending a pull
request, you agree that:

1. your contribution is your own work, or you have the right to submit it;
2. it's licensed under the GPL v3.0, like the rest of this repository; and
3. Starlight's developer (A2 Squared LLC) may also use it, and release it under other license
   terms, including in Starlight Pro.
