# Dish for macOS

Dish for macOS runs on your Mac and sends the controllers plugged into it, or paired with it over Bluetooth, to your gaming PC as wireless controllers.

Dish is made of two parts. The Dish apps run on the device that holds your controller, or that is the controller: Dish for Android, Dish for iOS, Dish for macOS, Dish for Windows and Dish for Linux. Satellite is the small server on the PC you play on, and it makes each Dish controller look to your games like a controller plugged into that PC. You need one of each. Everything is free and open source, the website is [dish.tinkernorth.com](https://dish.tinkernorth.com), and I maintain all of it on my own.

## Download

Dish for macOS 1.4.0 is the current release. Every link below always points at the newest one.

A Mac with Apple silicon and macOS 13 Ventura or later: download **[dish-mac.zip](https://github.com/TinkerNorth/dish-mac/releases/latest/download/dish-mac.zip)**, open it, and move Dish to your Applications folder. Dish checks for a new version itself and tells you once when there is one; you download it the same way.

Intel Macs are not supported. The release is built for Apple silicon only.

### Opening it the first time

I don't have an Apple Developer ID, so Dish isn't notarized, and macOS stops it the first time you open it. You let it through once, and after that it opens like any other app.

On macOS 15 Sequoia and later:

1. Open Dish. macOS says Apple could not verify that Dish is free of malware. Click Done.
2. Open System Settings, then Privacy & Security, and scroll down to Security. Beside the message about Dish, click Open Anyway, then enter your login password and click OK. The button stays there for about an hour after you tried to open the app.

On macOS 13 and 14, Control-click Dish in Finder, choose Open, and then click Open in the dialog.

Apple describes the same steps in [Open a Mac app from an unknown developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac). Check the download against its checksum first; how is under Trust and privacy.

All files and older versions are on the [releases page](https://github.com/TinkerNorth/dish-mac/releases).

### Satellite and the Dish apps

| App | Where to get it |
|---|---|
| Satellite (Windows, Linux) | [GitHub releases](https://github.com/TinkerNorth/satellite/releases/latest) |
| Dish for Android | [Google Play](https://play.google.com/store/apps/details?id=com.tinkernorth.dish), or the APK from [GitHub releases](https://github.com/TinkerNorth/dish-android/releases/latest) |
| Dish for iOS | Not yet released |
| Dish for macOS | [GitHub releases](https://github.com/TinkerNorth/dish-mac/releases/latest) |
| Dish for Windows | [GitHub releases](https://github.com/TinkerNorth/dish-windows/releases/latest) |
| Dish for Linux | [GitHub releases](https://github.com/TinkerNorth/dish-linux/releases/latest) |

## Getting started

1. Install Satellite on the PC you play on and start it. Its dashboard shows a 4-digit PIN under Device Pairing, with a new one every five minutes.
2. Install Dish on your Mac, plug your controller in or pair it in System Settings, Bluetooth, and open Dish. The Mac and the PC have to be on the same local network. The first launch shows a short welcome, and Finish starts Set up Dish.
3. Pair them. Before Dish looks for the PC, it explains that macOS will ask for Local Network access; allow it. The PC shows up in Set up Dish and on Connections. Click Pair… beside it and type the PIN from the dashboard into the 4-digit field. Dish also shows a PIN of its own at the same time; you can approve that request on the dashboard instead. Dish remembers the PC, so you only pair once.
4. Play. Set up Dish walks you through the controller, the PC, the type the game sees (Emulate as, from the types Satellite offers) and how it feels, and Bind on its last step makes it live. Set up in the sidebar runs it again, and Bind… on a controller on Home does the same for that one.

Closing the window keeps your controllers streaming. Quit from the menu bar icon.

## What it does

Dish reads each controller on your Mac and sends it to the PC you bound it to, where Satellite turns it into a virtual controller. Input travels over UDP on your own network, encrypted with a key the two computers agree on when they pair. Up to four controllers can go to one PC, and you can keep several PCs paired.

Most controllers reach Dish through macOS's own game controller support, over USB or Bluetooth: Xbox and PlayStation controllers, the Switch Pro Controller and MFi pads. A few that macOS doesn't read properly, Dish reads itself:

| Controller | Connection | What Dish does |
|---|---|---|
| Switch Pro Controller, Switch Online N64 and SNES pads | USB | Reads them directly, the Pro's motion included |
| 8BitDo Ultimate 2 in X-input mode, and other wired Xbox 360 style pads (Logitech F310, F510 and F710, PDP, Hori, PowerA, Razer and more) | USB | Reads them directly, because macOS has no driver for them |
| Steam Controller (2015 and 2026) | USB or Bluetooth | Reads it directly once you press Use Direct for it, with its back buttons and both trackpads |
| Other gamepads macOS doesn't support | USB | Guesses the layout; Check the buttons lets you correct it |

What goes to the PC: buttons, sticks and triggers, motion and the touchpad from a DualSense or DualShock 4, and the battery level. What comes back from the game: rumble, the light bar, and on a DualSense the adaptive triggers and player lights. Over USB, a DualSense or DualShock 4 can also carry your voice through its microphone and the PC's sound through its speaker, and a DualSense its HD haptics. An Xbox Elite Series 2's four paddles and a Steam Controller's back buttons reach the PC too, where a virtual DualSense Edge is the type that has back buttons to put them on.

Some of this is built but not yet confirmed on a real controller on a Mac: the controller's own microphone, speaker and HD haptics, both Steam Controllers, the 8BitDo Ultimate 2 and the other wired Xbox 360 style pads, the Elite's paddles, the SNES pad, and the layouts Dish guesses. A DualSense Edge works as a DualSense, but its back buttons aren't read yet.

Dish carries the list of controllers the whole Dish family recognises and checks for a newer one, so a new controller doesn't have to wait for a new release.

Diagnostics shows what each connection and controller is doing. Its inspector tests what a controller's path carries: rumble, trigger rumble, the light bar, the player lights, the adaptive triggers, a tone on the speaker and on the haptics, the microphone and the sticks, all from your Mac alone, and asks after each test whether it worked. Between that and Satellite's own view, you can tell whether a problem is the controller, the Mac or the PC.

Dish doesn't need Satellite to play on a Sunshine, Apollo or Wolf host. Connections has a page for Moonlight hosts that finds them on your network or takes an address, and Dish shows a PIN to type into the host. Dish is then the controller for that host; it never shows the stream. This path is tested against a stand-in host and not yet against a live one.

Dish can keep the Mac awake while you play. A closed lid still puts the Mac to sleep; Dish closes its sessions cleanly before it sleeps and opens them again when it wakes. It follows the system's light or dark appearance, or the one you pick, and speaks English, Bosnian, German, Spanish, French and Brazilian Portuguese.

## Requirements

A Mac with Apple silicon and macOS 13 Ventura or later. On macOS 15.4, a controller's input doesn't reach Dish while another app is in front; macOS 15.5 fixed that.

Dish is one app and installs nothing else. Its settings live in its own preferences, and the keys from pairing in your login keychain. macOS asks you for these permissions, each only when it's needed:

- Local Network, the first time Dish looks for a PC, to find Satellite and talk to it.
- Microphone, the first time you turn on a controller's own microphone or test it in the inspector.
- Input Monitoring, only when you press Use Direct for a Steam Controller (the 2026 one on a cable, or either one over Bluetooth), because it also acts as a keyboard and a mouse. Dish reads that controller and no other keyboard or mouse.
- Notifications, for one notice the first time closing the window leaves Dish running.

Dish asks for no Bluetooth permission: you pair a Bluetooth controller with macOS, and Dish reads it from there.

Network: the Mac and the PC on the same local network. Dish finds Satellite over mDNS and Satellite's older UDP beacon on port 9879, pairs and talks to it over HTTPS on TCP 9443, and streams on UDP 9876. If Dish can't find the PC, you can type its address on Connections.

## Trust and privacy

Every release has a `SHA256SUMS` file signed with cosign by the release workflow. To check a download on Linux, put `SHA256SUMS` beside it and run:

```bash
sha256sum --ignore-missing -c SHA256SUMS
```

On a Mac, `shasum -a 256 --ignore-missing -c SHA256SUMS` does the same. [SECURITY.md](SECURITY.md) has the signature and build provenance checks, and how to report a vulnerability.

The app is not signed with an Apple Developer ID and not notarized, because I don't have one yet. It carries only an ad-hoc signature, which is why macOS asks you to let it through once (the steps are under Download). The versioned copy on the release page is named `dish-1.4.0-unsigned.zip`; it is the same file as `dish-mac.zip`. The checksum and its signature are how you can tell it came from this repository's release. Once a Developer ID exists, the release workflow signs and notarizes the app with no other change.

Dish for macOS works on your own network and has no account, no analytics and no ads. Three things can leave your Mac, and each has a switch in Settings: a check for a new version, which reads `latest.json` from this repository's releases on GitHub at startup and every few hours (Check for updates automatically); a check for a newer controller database at dish.tinkernorth.com (Check for controller updates automatically); and, if Dish crashes, one crash report to Sentry (Share crash reports). All three are on by default. The update check downloads nothing; it tells you there is a new version and opens the release page when you ask. Controller input and the controller's microphone go only to the PC you paired with. The diagnostics file is something you send yourself; Dish never sends it. [PRIVACY.md](PRIVACY.md) says exactly what is stored and sent.

Dish for macOS is licensed under the GNU Lesser General Public License v3.0 or later ([LICENSE](LICENSE), with [COPYING.GPL3](COPYING.GPL3)). The third-party components and their licences are in [THIRD_PARTY.md](THIRD_PARTY.md).

## For developers

Dish for macOS is Swift, built with SwiftPM and Xcode 26 (the Swift 6.2 tools), with warnings as errors. The scripts are the ones CI calls:

```bash
scripts/setup-hooks.sh       # once, with Xcode 26 installed: the pre-commit hook
scripts/build-and-test.sh    # the debug build, then the tests
scripts/ci-local.sh          # every macOS CI gate, in CI's order
```

`scripts/build-app.sh` builds `Dish.app` the way a release does, and `scripts/launch-smoke.sh` starts a copy of it under its own bundle id, so your own settings are left alone.

Where things are written down:

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): the modules, the dataflow rules, the threads and the input hot path, the Direct reader and the project layout.
- [docs/contract.md](docs/contract.md): where each part of the Satellite protocol lives in this tree.
- [docs/UI_CONTRACT.md](docs/UI_CONTRACT.md): the window, the pages and the interface kit.
- [Tests/PARITY.md](Tests/PARITY.md): what this client has compared with the others, and what is confirmed on hardware.
- [CHANGELOG.md](CHANGELOG.md): what changed in each release.

[CONTRIBUTING.md](CONTRIBUTING.md) covers setting up, where code goes, the interface, translations, the code style, the tests, branching, what CI runs, how a release is cut, and changing the hot path or the wire protocol. Please read it before opening a pull request.

## Getting help

If something doesn't work, open an issue at [github.com/TinkerNorth/dish-mac/issues](https://github.com/TinkerNorth/dish-mac/issues/new/choose). The most useful thing you can attach is the diagnostics file: in Settings, open Diagnostics…, press Report a problem, say what happened and pick the controller, and press Continue in Mail; Preview file shows you the file first. The file leaves out pairing keys, addresses, Wi-Fi names and the names of your PCs; read it before you attach it, it's plain JSON. Continue in Mail starts a mail to support@tinkernorth.com with the file attached, so if you'd rather write to me than open an issue, send that mail; nothing leaves your Mac until you press Send.

Please also say which Dish for macOS version you run and how you installed it, your Mac and macOS version, which Satellite or Moonlight host and version you use, and which controller. If the problem is in Satellite rather than here, its own repository is the better place. For a security problem, don't open a public issue; [SECURITY.md](SECURITY.md) says how to report it privately.
