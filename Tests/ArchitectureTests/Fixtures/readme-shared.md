<!-- The family README's SHARED text, word for word as Satellite's README has it.
     DocumentFactsTests requires README.md to contain each block below verbatim.
     The template's sentence about the diagnostics file is shared only where a
     repository's PRIVACY.md says the same of its file; this one's names the
     controller's own product name, so it is not among them.
     When the family changes a SHARED block, it changes in all six READMEs and
     in this file in the same wave. Blocks are separated by a line holding only %%%. -->

Dish is made of two parts. The Dish apps run on the device that holds your controller, or that is the controller: Dish for Android, Dish for iOS, Dish for macOS, Dish for Windows and Dish for Linux. Satellite is the small server on the PC you play on, and it makes each Dish controller look to your games like a controller plugged into that PC. You need one of each. Everything is free and open source, the website is [dish.tinkernorth.com](https://dish.tinkernorth.com), and I maintain all of it on my own.
%%%
| App | Where to get it |
|---|---|
| Satellite (Windows, Linux) | [GitHub releases](https://github.com/TinkerNorth/satellite/releases/latest) |
| Dish for Android | [Google Play](https://play.google.com/store/apps/details?id=com.tinkernorth.dish), or the APK from [GitHub releases](https://github.com/TinkerNorth/dish-android/releases/latest) |
| Dish for iOS | Not yet released |
| Dish for macOS | [GitHub releases](https://github.com/TinkerNorth/dish-mac/releases/latest) |
| Dish for Windows | [GitHub releases](https://github.com/TinkerNorth/dish-windows/releases/latest) |
| Dish for Linux | [GitHub releases](https://github.com/TinkerNorth/dish-linux/releases/latest) |
%%%
Every release has a `SHA256SUMS` file signed with cosign by the release workflow. To check a download on Linux, put `SHA256SUMS` beside it and run:

```bash
sha256sum --ignore-missing -c SHA256SUMS
```
%%%
[SECURITY.md](SECURITY.md) has the signature and build provenance checks, and how to report a vulnerability.
%%%
[PRIVACY.md](PRIVACY.md) says exactly what is stored and sent.
%%%
For a security problem, don't open a public issue; [SECURITY.md](SECURITY.md) says how to report it privately.
