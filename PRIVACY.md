# Dish for macOS: Privacy Policy

**Effective date:** 2026-10-12.
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
- **Nothing leaves your network except the update check.** With the switch
  in Settings on (the default), the app fetches one small file from
  github.com at startup and every few hours to learn the newest version; it
  carries nothing about you, and section 2.3 lists what GitHub sees. The app
  sends no crash reports. There is no analytics SDK, no telemetry, no
  advertising identifier, no usage reporting and no account. Every other
  outbound connection goes to the satellite you chose, by its local address.
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
| `motion_preferences`, `rumble_preferences`, `touchpad_preferences` | Each controller's own switches, by the controller's vendor and kind (no serial number) | Deciding the same per controller |
| `theme_mode` | `system`, `light` or `dark` | Drawing the window in the appearance you chose |
| `background_run_enabled`, `background_notice_shown` | Whether closing the window keeps Dish running, and whether the one-time notice about it was shown | The close-to-background rule |
| `keep_awake_mode`, `keep_awake_timeout_minutes`, `keep_awake_display` | Your keep-awake mode, its stillness window and whether the display is held too | Deciding when to hold a power-management assertion |
| `updates_check_enabled`, `updates_skipped_version`, `updates_last_check_utc_ms` | Whether automatic update checks run, a version you chose to skip, and when the last check completed | The update check and its schedule |

Pairing keys are the long-lived trust root of the protocol and are not kept
in preferences. Each one is a login-keychain item with the service name
`com.tinkernorth.dish.pairing-key` and the satellite's id as its account name.
Forgetting a satellite deletes its key, its pin and its row.

Nothing else is written, with one exception: if the app crashes, a backtrace
is appended to `~/Library/Logs/Dish/crash.log` on your Mac (section 3). The
app keeps no other log file.

### 2.2 Sent to your own LAN, not to TinkerNorth

| Traffic | What it carries | Who receives it |
|---|---|---|
| Discovery: a Bonjour browse for `_satellite._udp` and a listener on UDP port 9879 | Nothing of yours is sent; the app reads the satellites' announcements | Your local network |
| Pairing and the control plane: HTTPS on port 9443 to the satellite you chose | Your `deviceId`, your Mac's name as shown in System Settings (the satellite lists paired devices by it), the PIN you typed or the app generated, the controller type and features you bound, and a proof of possession of the pairing key | The satellite |
| Streaming: encrypted UDP on port 9876 to the satellite you chose | Controller input (buttons, sticks, triggers), and, when the switches are on and the pad has them, motion samples, touchpad positions and the battery level of the pad or of your Mac | The satellite |
| Return paths over the same UDP channel | Rumble and light-bar commands from the satellite to the pad | Your Mac |

The streaming channel is encrypted with a key derived per session from the
pairing key; the HTTPS connection is pinned to the satellite's certificate.
Every address the app talks to is one it discovered on your network or one you
typed in.

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

There is no TinkerNorth server for this app to talk to and no crash reporter.
If a future version adds one, this policy will say so before it ships, with
the switch that turns it off.

The only other way this app causes a request to a TinkerNorth or third-party
address is if you click a link, which hands the URL to your default browser and
is then between you and that site.

---

## 3. Crash reports

None are sent. If the app crashes, it appends a backtrace to
`~/Library/Logs/Dish/crash.log` and stops; the next launch shows "Crash
report" in Settings. The report you see there has your home folder collapsed
to `~`, IP addresses and `.local` names replaced, and any long hexadecimal
run (what a key or an identifier looks like on a stack) removed. From there
you can copy it, open a prefilled issue in your browser with "Report on
GitHub", or discard the file. Nothing happens until you choose, and nothing
leaves this Mac unless you submit the issue yourself. Discarding deletes the
file; it is never read again.

macOS's own crash reporter may also write a report under
`~/Library/Logs/DiagnosticReports`; that file belongs to the system, not to
Dish, is not redacted, and may contain whatever the app held at that moment,
so treat it as sensitive before attaching it to a public issue.

---

## 4. System capabilities the app uses

| Capability | Why |
|---|---|
| Local network access and Bonjour (`_satellite._udp`) | Finding satellites and talking to the one you chose. Everything stays on your LAN. |
| GameController framework | Reading controller input, and writing rumble and light-bar output back to the controller. |
| Keychain | Storing the pairing key of each satellite. |
| A power-management assertion (IOKit) | Keeping the Mac awake while a bound controller is being used, or for as long as one is connected, as your keep-awake mode says; the display too only if you ask. Released when the condition ends. |
| User notifications | One notice, the first time closing the window leaves Dish running behind the menu-bar item. macOS asks you for permission before it is shown. |
| Host battery readout (IOKit) | Reporting your Mac's battery to the satellite in place of a pad that reports none. |

The app runs unsandboxed and asks for no other permission.

---

## 5. Your choices

- **Forget a satellite** in Connections: its key, pin and row are deleted and
  the satellite is told to drop this device.
- **Switch off a forwarded feature** in Settings: motion, rumble, the
  touchpad and the light bar each have their own switch.
- **Switch off automatic update checks** in Settings; nothing then leaves
  your network until you press "Check for updates" yourself.
- **Discard a crash log** from the "Crash report" row in Settings, or delete
  `~/Library/Logs/Dish/crash.log` yourself; the report is never sent for you.
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
