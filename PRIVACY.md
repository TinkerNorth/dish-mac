# Dish for macOS: Privacy Policy

**Effective date:** 2026-10-27.
**Canonical copy:** this file, at
[`https://github.com/TinkerNorth/dish-mac/blob/main/PRIVACY.md`](https://github.com/TinkerNorth/dish-mac/blob/main/PRIVACY.md).

This document describes what data the Dish macOS client collects, why, how
long it is retained, and the choices you have over it. The product as a whole
spans several repositories (`satellite`, `dish-android`, `dish-windows`,
`dish-linux`, `dish-mac`); this policy is specific to the macOS client. The
server (`satellite`) runs on your own machine and has its own policy. The other
clients have their own policies and different behaviour, so do not read one as
describing another.

---

## 1. Short version

- Dish for macOS turns a game controller plugged into your Mac into a wireless
  gamepad for a `satellite` server on your own network. Controller input goes
  from your Mac, over your own network, to the satellite you paired with. It
  does not stream to any TinkerNorth-operated server. TinkerNorth does not
  operate a server for Dish at all.
- **Nothing leaves your network except the update check and, with its
  switch on, a crash report.** With "Check for updates automatically" on
  (the default), the app fetches one small file from github.com at startup
  and every few hours to learn the newest version; it carries nothing about
  you, and section 2.3 lists what GitHub sees. With "Share crash reports" on
  (the default), an official release build that crashes sends one anonymous
  report to Sentry; section 3 says exactly what it holds, and the switch
  stops the very next one. There is no analytics SDK, no telemetry, no
  advertising identifier, no usage reporting and no account. Every other
  outbound connection goes to the satellite you chose, by its local address.
- **A controller's own microphone** (a DualSense's or DualShock 4's, over
  USB) is sent only to the satellite you paired with, only while that
  controller's mic switch is on and it is not muted. The switch is off until
  you turn it on; macOS asks your permission the first time; nothing is
  stored.
- Settings, remembered satellites and certificate pins live in your own
  preferences; pairing keys live in your login keychain. Nothing is synced to
  a cloud account by the app.
- We do not sell, share, or rent your data. We do not show ads. We do not
  profile you.

---

## 2. What data is processed

### 2.1 Stays on your Mac

Preferences are stored with `UserDefaults` in the app's preferences domain
(`com.tinkernorth.dish.mac` for the bundled app).

| Setting | Holds | Used for |
|---|---|---|
| `deviceId` | A random identifier generated on first launch (a UUID without dashes) | Telling the satellite which paired device is connecting. It is not derived from your hardware or your Apple ID. |
| `wifi_list` | The remembered satellites: display name, IP address, UDP and HTTPS ports, and the satellite's own machine id | Reconnecting to satellites you already paired with, also after their address changed |
| `cert_pin:<address>` | The SHA-256 fingerprint of the TLS certificate each satellite presented on first contact | Refusing a satellite whose certificate later changes (trust on first use) |
| `feature_motion_enabled`, `feature_rumble_enabled`, `feature_touchpad_enabled`, `feature_lightbar_mode` | Your forwarding switches | Deciding which controller features to forward or act on |
| `motion_preferences`, `rumble_preferences`, `touchpad_preferences`, `touchpad_mode_preferences`, `mic_preferences`, `speaker_preferences` | Each controller's own switches and touchpad pick, by the controller's vendor and kind (no serial number) | Deciding the same per controller |
| `deadzone:<controller>` | Each controller's stick and trigger dead zones, by the controller's vendor and kind | Applying the dead zones you set when the controller attaches |
| `usb_path_choices` | Which input path you picked for a controller model (Standard or Direct), by its USB vendor and product id (no serial number) | Reading that model through GameController or through Dish's own HID reader the next time it connects |
| `joystick_remaps` | The buttons you assigned with "Check the buttons" for a controller model, by its USB vendor and product id (no serial number) | Reading that model's buttons, triggers and stick directions as you set them |
| Nothing stored: "Help support this controller" | While its page shows, the controller's USB vendor and product id, name, maker, connection, HID report descriptor and the raw reports it sends as you press each control, held in memory | Showing you a plain-text report. Nothing leaves your Mac unless you copy it and paste it somewhere yourself; "Open a GitHub issue" opens the issue page in your browser with only a title, and the report is not attached |
| `wifi_binding_list` | Which controller is bound to which satellite, by the controller's vendor and kind and the satellite's machine id (both already kept above), and the controller type picked for it | Binding a controller to its satellite again after a restart or a replug |
| `theme_mode` | `system`, `light` or `dark` | Drawing the window in the appearance you chose |
| `background_run_enabled`, `background_notice_shown` | Whether closing the window keeps Dish running, and whether the one-time notice about it was shown | The close-to-background rule |
| `keep_awake_mode`, `keep_awake_timeout_minutes`, `keep_awake_display` | Your keep-awake mode, its stillness window and whether the display is held too | Deciding when to hold a power-management assertion |
| `updates_check_enabled`, `updates_skipped_version`, `updates_last_check_utc_ms` | Whether automatic update checks run, a version you chose to skip, and when the last check completed | The update check and its schedule |
| `crashlytics_collection_enabled` | Whether *Share crash reports* is on (the fleet's key name) | Deciding whether a crash report may be sent (section 3) |
| `ui_rail_collapsed`, `onboarding_welcome_completed`, `local_network_primed` | Whether the window's rail is collapsed, whether the welcome was finished or skipped, and whether the Local Network prompt was explained once | Drawing the window as you left it and showing the welcome and the explanation only once |
| `moonlight_host_list` | The remembered Moonlight hosts: name, address, HTTP and HTTPS ports, the id the host answers with, the app picked for it, the controller type picked for it, and whether it ever accepted this device | Pairing with and starting sessions on Moonlight hosts you added or paired with |
| `moonlight_binding_list` | Which controller is bound to which Moonlight host, by the controller's vendor and kind, and the type it is plugged in as | Putting a controller back on its host |
| `moonlight_uniqueid` | A random sixteen-character id generated on first use | The name a Moonlight host files this device under; not derived from your hardware or your Apple ID |
| `cert_pin:moonlight:<address>` | The SHA-256 fingerprint of the certificate each Moonlight host presented on first contact, replaced by the one a pairing proves | Refusing a host whose certificate later changes |

Pairing keys are the long-lived trust root of the protocol and are not kept
in preferences. Each one is a login-keychain item with the service name
`com.tinkernorth.dish.pairing-key` and the satellite's id as its account name.
Forgetting a satellite deletes its key, its pin, its row and the bindings
remembered for it.

The Moonlight identity, an RSA key and the self-signed certificate around it,
is minted once in the login keychain (labelled "Dish Moonlight client key" and
"Dish Moonlight client certificate") and presented to every Moonlight host:
it is how a host recognises a device it paired with. Forgetting a host deletes
the host's record, its bindings and its pin on this side; the protocol has no
unpair verb, so the host keeps its own record of this device until you remove
it there.

Nothing else is written, with one exception: if the app crashes, a backtrace
is appended to `~/Library/Logs/Dish/crash.log` on your Mac (section 3). The
app keeps no other log file.

### 2.2 Sent to your own LAN, not to TinkerNorth

| Traffic | What it carries | Who receives it |
|---|---|---|
| Discovery: a Bonjour browse for `_satellite._udp`, a listener on UDP port 9879, and one empty UDP flow to your router's discard port (9) | Nothing of yours is sent; the app reads the satellites' announcements, and the flow to the router only tells it whether macOS lets it on the network | Your local network |
| Pairing and the control plane: HTTPS on port 9443 to the satellite you chose | Your `deviceId`, your Mac's name as shown in System Settings (the satellite lists paired devices by it), the PIN you typed or the app generated, the controller type and features you bound, and a proof of possession of the pairing key | The satellite |
| Streaming: encrypted UDP on port 9876 to the satellite you chose | Controller input (buttons, sticks, triggers), and, when the switches are on and the pad has them, motion samples, touchpad positions and the battery level of the pad or of your Mac; with that controller's mic switch on and not muted, the sound its own microphone hears, as 20 ms Opus frames | The satellite |
| Return paths over the same UDP channel | Rumble, light-bar, adaptive-trigger, player-LED and mic-lamp commands from the satellite to the pad, and the host's voice chat and haptics audio for the pad's own speaker and actuators | Your Mac |
| Moonlight discovery: a Bonjour browse for `_nvstream._tcp` | Nothing of yours is sent; the app reads the hosts' announcements | Your local network |
| Moonlight pairing: HTTP on port 47989 and HTTPS on port 47984 to the host you chose | Your `moonlight_uniqueid`, the device name the protocol fixes (`roth`), the app's certificate, and a salt and challenges derived from the PIN the app showed you; the PIN itself never crosses the wire | The Moonlight host |
| Moonlight sessions: HTTPS on port 47984 (mutual TLS with the app's certificate), RTSP on the port the host names (48010 by default) and encrypted UDP to the host's control port | The app to start, a key minted per session, the controller type and features each pad is plugged in as, and then controller input (buttons, sticks, triggers), and, when the switches are on and the pad has them, motion samples, touchpad positions and the battery level of the pad or of your Mac | The Moonlight host |
| Return path over the same UDP channel | Rumble and light-bar commands from the host for the pad | Your Mac |

The streaming channel is encrypted with a key derived per session from the
pairing key; the HTTPS connection is pinned to the satellite's certificate. A
Moonlight control stream is encrypted with the key the app minted for that
session, and the host's certificate is pinned on first contact and replaced
by the one a pairing proves. Every address the app talks to is one it
discovered on your network or one you typed in.

### 2.3 Sent to TinkerNorth or a third party

**The update check** is the one request this app makes beyond your network.
At startup and every few hours, and when you press "Check for updates", the
app fetches
`https://github.com/TinkerNorth/dish-mac/releases/latest/download/latest.json`,
a small file published with each release that names the newest version, its
publication date, the oldest version still supported and a link to the release
notes. The request is a plain HTTPS GET with no body, no cookies and no
identifier of yours; like every web request it carries your IP address and the
system's standard user-agent header, and GitHub receives them under GitHub's
own privacy statement. The app reads the version and the link, and nothing is
downloaded or installed: the release page opens in your browser only when you
ask. The switch "Check for updates automatically" in Settings stops the
scheduled checks; the manual button fetches only when pressed. The time of the
last completed check and a version you chose to skip stay in your preferences
(section 2.1).

**A crash report** is the one thing that reaches us, through Sentry, and
only if you leave "Share crash reports" on. Section 3 describes it.

There is no TinkerNorth server for this app to talk to.

The only other way this app causes a request to a TinkerNorth or third-party
address is if you click a link, which hands the URL to your default browser and
is then between you and that site.

---

## 3. Crash reports

This is the part most likely to be misread, so it is stated plainly.

**What is written locally, always.** If the app crashes, its own handler
appends a backtrace to `~/Library/Logs/Dish/crash.log` and stops; the next
launch shows "Crash report" in Settings. The report you see there has your
home folder collapsed to `~`, IP addresses and `.local` names replaced, and
any long hexadecimal run (what a key or an identifier looks like on a stack)
removed. From there you can copy it, open a prefilled issue in your browser
with "Report on GitHub", or discard the file. Nothing happens until you
choose, and nothing leaves this Mac through that card unless you submit the
issue yourself. Discarding deletes the file; it is never read again. The
switch below does not touch any of this: the reporting SDK hands the crash
on to Dish's own handler, so the local log is written whether the switch is
on or off.

**What is uploaded, and when.** Settings has a *Share crash reports* switch,
on by default. With it on, an official release build that crashes sends one
report to [Sentry](https://sentry.io), a crash-reporting service operated by
Functional Software, Inc. (San Francisco, USA), which processes it on our
behalf. The report is produced by the Sentry SDK for Apple platforms, which
the app arms only after reading your preference, and contains:

- the stack of the crashing thread and the list of loaded modules with their
  versions, so we can see where it failed;
- the app version and a build environment label, the macOS version and CPU
  architecture, the Mac's model name, and a random event id.

It does **not** contain your controller input, your pairings, keys or
settings, your user name, your Mac's name, or a device identifier, and the
app never reports launches, sessions, breadcrumbs or usage: the crash is the
only event. Sentry sees the public IP address of your Mac when it receives
the report, as any web service does; the app does not attach it and we do
not use it. Sentry retains crash data for 90 days, then deletes it. We use
Sentry's US region, so the data is stored in the United States. See Sentry's
[privacy policy](https://sentry.io/privacy/) for its role as a processor.

**Opting out.** Turn *Share crash reports* off. The switch closes the SDK
immediately and puts Dish's own handlers back as they were, so it stops the
very next report, not just later ones, and the choice persists in your
preferences. Opting out never costs you the local log above.

**Where the SDK keeps its state.** With the switch on, the SDK keeps its run
state and any report it has not yet sent under
`~/Library/Caches/com.tinkernorth.dish.mac/io.sentry/`. Delete that folder at
any time; the app recreates it only while the switch is on.

**Builds that cannot upload.** Only official release builds from this
repository carry the Sentry address (DSN) that the SDK needs; `bundle.sh`
writes it into the app's `Info.plist` from a release-time secret. A
`swift run` binary, a pull-request build or a fork carries none and cannot
upload, whatever the switch says; Settings says so beneath the switch.

macOS's own crash reporter may also write a report under
`~/Library/Logs/DiagnosticReports`; that file belongs to the system, not to
Dish, is not redacted, and may contain whatever the app held at that moment,
so treat it as sensitive before attaching it to a public issue.

---

## 4. System capabilities the app uses

| Capability | Why |
|---|---|
| Local network access and Bonjour (`_satellite._udp`, `_nvstream._tcp`) | Finding satellites and talking to the one you chose. Everything stays on your LAN. |
| GameController framework | Reading controller input, and writing rumble and light-bar output back to the controller. |
| Keychain | Storing the pairing key of each satellite. |
| A power-management assertion (IOKit) | Keeping the Mac awake while a bound controller is being used, or for as long as one is connected, as your keep-awake mode says; the display too only if you ask. Released when the condition ends. |
| User notifications | One notice, the first time closing the window leaves Dish running behind the menu-bar item. macOS asks you for permission before it is shown. |
| Host battery readout (IOKit) | Reporting your Mac's battery to the satellite in place of a pad that reports none. |
| Microphone (a controller's own, over USB) | Sending the pad's microphone to the satellite as the emulated pad's mic. macOS asks you the first time a controller's mic switch is turned on; the switch is off until you turn it on, and muting sends nothing at all. |
| `~/Library/Caches/com.tinkernorth.dish.mac/io.sentry/` file write | The crash reporter's run state and any report not yet sent (section 3), only while *Share crash reports* is on. |

The app runs unsandboxed and asks for no other permission.

---

## 5. Your choices

- **Forget a satellite** in Connections: its key, pin and row are deleted and
  the satellite is told to drop this device.
- **Switch off a forwarded feature** in Settings: motion, rumble, the
  touchpad and the light bar each have their own switch.
- **Keep a controller's microphone off** (the default), or mute it from the
  chip on its card or the one in the header; muted sends no audio at all.
- **Switch off automatic update checks** in Settings; nothing then leaves
  your network until you press "Check for updates" yourself.
- **Switch off "Share crash reports"** in Settings; the SDK closes at once
  and the next crash writes only the local log.
- **Discard a crash log** from the "Crash report" row in Settings, or delete
  `~/Library/Logs/Dish/crash.log` yourself; that report is never sent for you.
- **Quit from the menu-bar item**, or switch off "Keep running in the
  background" so closing the window quits.
- **Reset everything** by deleting the app's preferences domain and the
  keychain items with the service name above.

---

## 6. Children's privacy

Dish is a utility and is not directed at children. It collects no personal
information from anyone, and no account exists.

## 7. International transfers

The update check reaches GitHub's servers, wherever GitHub serves the file
from, and carries no personal data beyond the IP address every web request
has. Everything else stays on your own network.

## 8. Changes to this policy

Changes land in this file with a new effective date, in the same change as the
code that makes them necessary. The repository's history is the record.

## 9. Contact

Questions about this policy: open an issue in the repository, or email
`security@tinkernorth.com` for anything that should stay private.
