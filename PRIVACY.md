# Dish for macOS: Privacy Policy

**Effective date:** 2026-11-22.
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
- **Nothing leaves your network except the two update checks and, with its
  switch on, a crash report.** With "Check for updates automatically" on
  (the default), the app fetches one small file from github.com at startup
  and every few hours to learn the newest version; it carries nothing about
  you, and section 2.3 lists what GitHub sees. With "Check for controller
  updates automatically" on (the default), it fetches a small manifest from
  dish.tinkernorth.com ten seconds after launch and every six hours, and the
  newer controller list only when there is one (section 2.4). A diagnostics
  file reaches us only if you mail it yourself (section 2.5). With "Share crash reports" on
  (the default), an official release build that crashes sends one anonymous
  report to Sentry; section 3 says exactly what it holds, and the switch
  stops the very next one. There is no analytics SDK, no telemetry, no
  advertising identifier, no usage reporting and no account. Every other
  outbound connection goes to the satellite you chose, by its local address.
- **A controller's own microphone** (a DualSense's or DualShock 4's, over
  USB) is sent only to the satellite you paired with, only while that
  controller's mic switch is on and it is not muted. The switch is off until
  you turn it on; macOS asks your permission the first time; nothing is
  stored. The one other time it opens is the inspector's microphone test,
  which you start yourself: it shows a level meter for up to eight seconds,
  and what it hears is not recorded, kept or sent.
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
| `usb_path_choices` | Which input path you picked for a controller model (Standard or Direct), by its USB or Bluetooth vendor and product id (no serial number) | Reading that model through GameController or through Dish's own HID reader the next time it connects |
| `joystick_remaps` | The buttons you assigned with "Check the buttons" for a controller model, by its USB vendor and product id (no serial number) | Reading that model's buttons, triggers and stick directions as you set them |
| Nothing stored: "Help support this controller" | While its page shows, the controller's USB vendor and product id, name, maker, connection, HID report descriptor and the raw reports it sends as you press each control, held in memory | Showing you a plain-text report. Nothing leaves your Mac unless you copy it and paste it somewhere yourself; "Open a GitHub issue" opens the issue page in your browser with only a title, and the report is not attached |
| `wifi_binding_list` | Which controller is bound to which satellite, by the controller's vendor and kind and the satellite's machine id (both already kept above), and the controller type picked for it | Binding a controller to its satellite again after a restart or a replug |
| `theme_mode` | `system`, `light` or `dark` | Drawing the window in the appearance you chose |
| `background_run_enabled`, `background_notice_shown` | Whether closing the window keeps Dish running, and whether the one-time notice about it was shown | The close-to-background rule |
| `keep_awake_mode`, `keep_awake_timeout_minutes`, `keep_awake_display` | Your keep-awake mode, its stillness window and whether the display is held too | Deciding when to hold a power-management assertion |
| `updates_check_enabled`, `updates_skipped_version`, `updates_last_check_utc_ms` | Whether automatic update checks run, a version you chose to skip, and when the last check completed | The update check and its schedule |
| `controller_db_check_enabled`, `controller_db_last_check_utc_ms`, `controller_db_last_check_result`, `controller_db_manifest_etag` | Whether the controller database is checked automatically, when the last check ran and how it ended, and the manifest's ETag the website gave | The controller database check and its schedule (section 2.4) |
| `~/Library/Application Support/Dish/controllers-v1/` (files, not preferences) | The newest controller list the website published, its text in each language and its manifest, once one newer than the app's own was downloaded | Recognising controllers released after this version of the app |
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
is minted once in the login keychain (the key labelled "Dish Moonlight client
key"; the certificate is filed under the name it was issued to, and Dish finds
it again by the key it belongs to) and presented to every Moonlight host:
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
| A support report's question to each connected satellite: HTTPS on port 9443, `GET /api/connections/{id}/diagnostics`, only as the report page opens and only to a Satellite of 2.3.0 or later | Your `deviceId` and the proof of the pairing key, as every control-plane request; the satellite answers with its view of this connection (section 2.5), which stays on your Mac unless you mail it | The satellite |
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

**The controller database check** goes to `dish.tinkernorth.com`, the
TinkerNorth website; section 2.4 describes it.

**A crash report** reaches us through Sentry only if you leave "Share crash
reports" on; section 3 describes it. **A diagnostics file** reaches us only
if you mail it yourself; section 2.5 describes it.

Beyond the website's static files there is no TinkerNorth server for this
app to talk to.

The only other way this app causes a request to a TinkerNorth or third-party
address is if you click a link, which hands the URL to your default browser and
is then between you and that site.

### 2.4 Controller database updates

Dish ships with a list of the controllers it recognises: their USB and
Bluetooth ids, how each one talks, and the known issues its Diagnostics card
shows. So that a newly supported controller does not wait for an app
release, the app checks for a newer list. About ten seconds after launch,
and then every six hours while it runs, it fetches a small manifest from
`https://dish.tinkernorth.com/controllers/v1/` that names the newest
version. Only when that version is newer than the one the app has does it
fetch the rest: the controller list and its text in each language. These
files are data, never code. The app checks each one's size and SHA-256
checksum against the manifest before using it, and keeps the copy it has
when anything does not match. A downloaded list is kept under
`~/Library/Application Support/Dish/controllers-v1/` (section 2.1).

`dish.tinkernorth.com` is an Amazon S3 bucket behind Amazon CloudFront,
operated for TinkerNorth by Amazon Web Services. The requests carry no
identifier, no cookie and no query, and use the system's default user agent;
the manifest request repeats the ETag the website last gave, so an unchanged
manifest is answered with "not modified". What the host's access logs can
see is what any web server sees: the IP address the request came from, and
the time. We use those logs as we use the rest of the website's: for
capacity planning and abuse detection only.

*Check for controller updates automatically* in Settings, on by default,
turns the check off. With it off, no request for the controller list leaves
your Mac, and the app keeps using the copy it has. *Check now* runs one
check when you press it, and sends nothing while the switch is off. Every
build of Dish for macOS makes this check; there is no store build.

### 2.5 Diagnostics by email

When something does not work, you can write to us from the app's
Diagnostics page. Nothing happens unless you start it. *Report a problem*
and *Ask a question* open one page where you pick what it is about, write
what happened in your own words, and pick the controller it concerns. The
page lists what the file will hold, and *Preview file* shows you the file
itself before anything moves. *Continue in Mail* writes one file,
`dish-diagnostics-dish-mac-<date>-<time>.json`, to a temporary folder and
hands it to your own mail app, in a new message addressed to
`support@tinkernorth.com` with your words first and the page's summary
after them. Nothing is sent until you press Send in your mail app, and you
can read the file or remove it first. The message then travels like any
email you send, through your own mail provider. When no mail app takes it,
the file is saved where you pick instead. *Save diagnostics* saves a file
without your words, without a host's own view and without your Mac's
conditions, where you pick, and it goes nowhere.

Opening the report page asks each host Dish is connected to right now, on
your own network and over the same encrypted, paired connection Dish
already uses, for its own view of that connection; nothing goes to
TinkerNorth or anyone else at that moment. A Satellite of version 2.3.0 or
later answers with what it sees of this Mac's session: its own version and
platform, its virtual controller backends, each controller Dish asked for
as it applied it, how many reports went each way, which audio lanes it
grants, its controller database version and its own log lines for this
connection, with its machine name, other devices and every secret already
removed by Satellite and named only "this connection". An older Satellite
is not asked; the file carries what Dish already learned from it when it
connected (its version, protocol, backends and audio switches) instead. A
Moonlight host is not asked; the file carries its app version, never its
name.

The file holds:

- the app's version and build;
- your Mac's model identifier (such as `Mac14,2`), its macOS version and its
  processor architecture;
- which controller database version the app uses, where it came from, and
  when the last check ran and how it ended;
- for each attached controller, its identity and hardware facts: the USB or
  Bluetooth ids, the product and maker names the controller reports, its
  version number, on USB a fingerprint (SHA-256) of its USB descriptors and
  its interfaces' numbers, classes and endpoint addresses as macOS lists
  them, its USB audio function's channel count and whether macOS refused
  it, how it is
  connected, how Dish reads it, the controller database record it matched,
  what its hardware showed at attach against that record, and the last report
  Dish sent it with the answer macOS gave; none of it identifies the unit,
  and its serial number is never read;
- for each attached controller, how much went in and came out as counts:
  the reports it sent and its rate, the last report Dish forwarded (its
  buttons, sticks and triggers at that instant, not a recording), and for
  rumble, the light bar, the player lights and the trigger effects how many
  commands reached it, the newest one and when; whether its speaker and
  haptics voices were open, and for a Bluetooth controller that macOS reads
  it as HID and whether over classic Bluetooth or Bluetooth Low Energy, as
  macOS names the link, never its Bluetooth address;
- the results of the tests you ran on a controller in the inspector and
  confirmed, such as whether you felt the rumble;
- the hosts you use, as "Host 1", "Host 2", with their kind, version,
  protocol, link state and which audio lanes they granted, never their names
  or addresses; for a host with a session, Dish's own view of it (each
  controller as asked and as applied, the last heartbeat's facts, the round
  trip, how many messages of each kind went each way); and, in a report,
  what the host said of the connection as described above, with any name of
  a host replaced by its alias;
- only in a report: what you wrote, the category you picked and the
  controller you picked, by its database record or the name it reports;
  your Mac's battery level and whether it is charging, its thermal state,
  whether Low Power Mode is on, the Wi-Fi band, signal strength and link
  rate, read once through macOS's CoreWLAN, never the network's name or the
  access point's address, and whether macOS lists a USB host controller, as
  a yes or a no;
- the app's flight recorder, the lines Diagnostics shows, with every host
  named by its alias;
- only if you ran "Help support this controller" this session, that
  controller's capture: its ids, names and connection, on USB its device
  and configuration descriptors (which describe the model, never its serial
  number), its HID report descriptor, the first twenty reports it sent while
  at rest with when each arrived, and the reports it sent as you pressed
  each control, also as the page showed them; in a report, only when it is
  the controller you picked.

Every fact about your Mac and your controllers is read from macOS on this
Mac, and only this file carries any of them away: reading them sends
nothing anywhere, and Dish opens no controller to read them, beyond the one
you chose to capture with "Help support this controller". It never holds pairing keys, pairing
secrets, certificate fingerprints, IP addresses, Wi-Fi names, the names you
gave your hosts or devices, a controller's serial number, or anything from a
controller's microphone or speaker. Your own words are only what you
typed; Dish adds nothing to them and sends them nowhere but into the message
your mail app opens.

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
| Host battery readout (IOKit power sources) | Reading your Mac's internal battery from macOS's list of power sources (`IOPSCopyPowerSourcesInfo`): its charge as a percentage of its capacity, and whether it is charging, full or discharging. Any other power source, such as a UPS, is skipped, and a Mac with no internal battery reads as 100 % on mains power. For a controller bound to a satellite or a Moonlight host, Dish sends the lower of the controller's own battery and the Mac's, with the charging state of the one it sends (an unknown level counts as the higher, and a tie goes to the controller); a controller that reports no battery of its own sends the Mac's. A controller that is not bound sends neither. The Mac's battery is read, and the result sent, a second after a controller shows and every 30 seconds after; in between, a controller on the Standard path reads it every 3 seconds and sends only when the charging state to send has changed, and a controller on the Direct path reads and sends it whenever its own reading changes. The controller's card shows the controller's own reading (the Mac's, for a controller on the Standard path that reports none). |
| Input Monitoring (macOS asks) | Reading a controller that is also a keyboard or a mouse, such as a Steam Controller (the 2026 one on a cable, or either one over Bluetooth), only when you press Use Direct for it. Dish reads the controller's own reports to forward its buttons, sticks, trackpads and motion; it reads no other keyboard or mouse and records no typing. Refusing leaves the controller as it was. |
| Microphone (a controller's own, over USB) | Sending the pad's microphone to the satellite as the emulated pad's mic. macOS asks you the first time a controller's mic switch is turned on; the switch is off until you turn it on, and muting sends nothing at all. The inspector's microphone test opens the same microphone for up to eight seconds when you start it, to show a level meter; what it hears is measured and dropped, never encoded, stored or sent. |
| Wi-Fi link readout (CoreWLAN) | Only as a report opens: the current Wi-Fi interface's band, signal strength (RSSI) and transmit rate, for the file you choose to mail. Dish never reads the network's name or the access point's address, so macOS's location permission is never asked. |
| USB and HID device facts (IOKit registry and IOUSBLib) | For the diagnostics file only: as a report opens, whether macOS lists a USB host controller, counted in the IORegistry and written as a yes or a no; and each attached controller's version number, USB interfaces and endpoints, and the descriptors its USB device gave macOS as it was plugged in (fingerprinted, and in a capture written out), read as the controller attaches or as the Diagnostics page shows it. Nothing opens the controller or sends it a request to read them, and nothing leaves the Mac until you send the file. |
| `~/Library/Caches/com.tinkernorth.dish.mac/io.sentry/` file write | The crash reporter's run state and any report not yet sent (section 3), only while *Share crash reports* is on. |

The app runs unsandboxed and asks for no other permission than these.

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
- **Switch off "Check for controller updates automatically"** in Settings;
  no request for the controller list then leaves your Mac, and deleting
  `~/Library/Application Support/Dish/controllers-v1/` returns the app to
  the list it shipped with.
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
from, and the controller database check reaches Amazon CloudFront, wherever
it serves the website from; neither carries personal data beyond the IP
address every web request has. A diagnostics file you mail travels through
your own mail provider. Everything else stays on your own network.

## 8. Changes to this policy

Changes land in this file with a new effective date, in the same change as the
code that makes them necessary. The repository's history is the record.

## 9. Contact

Questions about this policy: open an issue in the repository, or email
`security@tinkernorth.com` for anything that should stay private.
