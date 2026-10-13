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
- **Nothing leaves your network.** This version makes no update check and
  sends no crash reports. There is no analytics SDK, no telemetry, no
  advertising identifier, no usage reporting and no account. The only
  outbound connections the app opens go to the satellite you chose, by its
  local address.
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

Pairing keys are the long-lived trust root of the protocol and are not kept
in preferences. Each one is a login-keychain item with the service name
`com.tinkernorth.dish.pairing-key` and the satellite's id as its account name.
Forgetting a satellite deletes its key, its pin and its row.

Nothing else is written. The app keeps no log file and no crash file.

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

Nothing. There is no TinkerNorth server for this app to talk to, no crash
reporter and no update check in this version. If a future version adds either,
this policy will say so before it ships, with the switch that turns it off.

The only way this app causes a request to a TinkerNorth or third-party address
is if you click a link, which hands the URL to your default browser and is then
between you and that site.

---

## 3. Crash reports

None are written and none are sent. If the app crashes, macOS's own crash
reporter may write a report under `~/Library/Logs/DiagnosticReports`; that
file belongs to the system, not to Dish, and may contain whatever the app held
at that moment, so treat it as sensitive before attaching it to a public issue.

---

## 4. System capabilities the app uses

| Capability | Why |
|---|---|
| Local network access and Bonjour (`_satellite._udp`) | Finding satellites and talking to the one you chose. Everything stays on your LAN. |
| GameController framework | Reading controller input, and writing rumble and light-bar output back to the controller. |
| Keychain | Storing the pairing key of each satellite. |
| A power-management assertion (IOKit) | Keeping the display awake while a controller is actively streaming, released when streaming stops. |
| Host battery readout (IOKit) | Reporting your Mac's battery to the satellite in place of a pad that reports none. |

The app runs unsandboxed and asks for no other permission.

---

## 5. Your choices

- **Forget a satellite** in Connections: its key, pin and row are deleted and
  the satellite is told to drop this device.
- **Switch off a forwarded feature** in Settings: motion, rumble, the
  touchpad and the light bar each have their own switch.
- **Reset everything** by deleting the app's preferences domain and the
  keychain items with the service name above.

---

## 6. Children's privacy

Dish is a utility and is not directed at children. It collects no personal
information from anyone, and no account exists.

## 7. International transfers

No data leaves your own network, so none is transferred anywhere.

## 8. Changes to this policy

Changes land in this file with a new effective date, in the same change as the
code that makes them necessary. The repository's history is the record.

## 9. Contact

Questions about this policy: open an issue in the repository, or email
`security@tinkernorth.com` for anything that should stay private.
