# AirControl Communication Protocol Specification (v2.0)

This document defines the transport layer, binary datagram formats, command schemas, Wake-on-LAN mechanics, and SideStore community repository specifications for AirControl.

---

## 1. Network Topology & Transport Architecture

AirControl adopts a high-efficiency transport architecture tailored for Apple native ecosystems while remaining platform-agnostic for future desktop extensions (Windows / Linux):

| Transport Layer | Channel | Reliability | Format | Frequency | Purpose |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Apple Multipeer Connectivity** (`aircontrol-p2p`) | **Motion Stream** | `MCSessionSendDataMode.unreliable` | Fixed 16-Byte Binary | 120Hz ProMotion | Cursor displacement, inertial scroll, click, drag |
| **Apple Multipeer Connectivity** (`aircontrol-p2p`) | **Control Stream** | `MCSessionSendDataMode.reliable` | UTF-8 JSON | Event-driven | Key events, Unicode text commit, Dock, media, power |
| **UDP Broadcast** (Port `9` & `7`) | **Wake-on-LAN** | Unacknowledged UDP | Fixed 102-Byte Magic Packet | On-demand (3-burst) | Remote power-on/wake from sleep (0.5W standby) |
| **GitHub Releases & SideStore** | **Cloud Update** | HTTPS JSON / IPA | AltStore/SideStore Source | On-demand | In-place app upgrade without 3-app slot exhaustion |
| **Local HTTP Update Server** (Port `8923`) | **LAN Offline Update** | Standard HTTP/1.1 | Binary Stream / JSON | On-demand | LAN SideStore install & IPA fallback |

### Advantages of Apple Native Multipeer Connectivity:
* **Direct Hardware Link**: Uses Apple Wireless Direct Link (AWDL), Wi-Fi Direct, and Bluetooth Low Energy (BLE).
* **Zero Configuration**: No manual IP input, no subnet collisions, immune to router client isolation and multicast packet loss.
* **Zero Head-of-Line Blocking**: 120Hz motion packets are dispatched via `.unreliable` hardware datagrams without socket buffer queuing.

---

## 2. Motion Channel: 16-Byte Binary Datagram & Jitter Suppression

All mouse pointer, click, and scroll events are packed into a fixed 16-byte binary structure in **Big Endian (Network Byte Order)**:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|   Magic(0xA8) |   Event Type  |        Sequence Number        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     Delta X (float32, IEEE 754)               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     Delta Y (float32, IEEE 754)               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|          Finger Count         |             Flags             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 2.1 Field Definitions

1. **`Magic`** (`uint8_t`, offset 0): Fixed `0xA8`. Non-matching datagrams are dropped immediately.
2. **`Event Type`** (`uint8_t`, offset 1):
   * `0x01` — **Pointer Move**: Relative cursor displacement (`dx`, `dy`).
   * `0x02` — **Scroll Wheel**: Two-finger pixel scrolling (`dx`, `dy`).
   * `0x03` — **Pointer Drag**: Cursor movement with left button down.
   * `0x04` — **Click Event**: Discrete mouse click (left/right/double indicated in `Flags`).
   * `0x05` — **Drag Release**: Mouse drag cancelled / finger lifted.
3. **`Sequence Number`** (`uint16_t`, offset 2-3):
   * Monotonically increasing counter ($0 \to 65535 \to 0$).
   * Host drops out-of-order packets: `if ((int16_t)(seq - last_seq) <= 0 && diff > -1000) drop;`.
4. **`Delta X`** (`float32`, offset 4-7): Logical displacement points.
5. **`Delta Y`** (`float32`, offset 8-11): Logical displacement points.
6. **`Finger Count`** (`uint16_t`, offset 12-13): Active contact count (1 = cursor, 2 = scroll).
7. **`Flags`** (`uint16_t`, offset 14-15):
   * Bit 0 (`0x01`): Left click
   * Bit 1 (`0x02`): Right click
   * Bit 3 (`0x08`): Double click

### 2.2 Host Anti-Jitter Pipeline & Event Tap
* **One Euro Filter**: macOS agent applies a dynamic 1€ filter (`minCutoff = 1.0`, `beta = 0.015`, `dCutoff = 1.0`) to suppress touch sensor noise and finger tremor during slow navigation while scaling cutoffs during rapid swipes to guarantee zero lag.
* **Pure Absolute Target Placement**: `CGEventCreateMouseEvent(nil, type, targetPoint, .left)` is used without `.mouseEventDeltaX` or `.mouseEventDeltaY`, eliminating WindowServer double-accumulation stutter.
* **Session Event Tap**: Events post to `.cgSessionEventTap` (`kCGSessionEventTap`) bypassing legacy HID filter chain bottlenecks.
* **Multi-Display Boundary Snapping**: Clamps cursor coordinates using `CGGetDisplaysWithPoint` and `CGDisplayBounds`.

---

## 3. Control Channel: JSON Schemas

### 3.1 Handshake & Host Info
```json
// iOS Query
{ "type": "host_query" }

// Host Response
{
  "type": "host_ack",
  "host_name": "Aaron's MacBook Pro",
  "os": "macOS",
  "ver": "2.0",
  "local_ip": "192.168.1.100",
  "mac_address": "3C:06:30:4F:2E:11",
  "power_state": "awake",
  "update_port": 8923
}
```

### 3.2 Keyboard & Unicode Text Commit
```json
// Shortcut or Key Event
{
  "type": "key_event",
  "key_code": 49,
  "action": "down",
  "modifiers": { "cmd": true, "opt": false, "ctrl": false, "shift": false }
}

// Unicode IME Commit
{
  "type": "text_commit",
  "text": "你好，AirControl！"
}
```

### 3.3 Media & Volume Controls
```json
{
  "type": "media_command",
  "action": "volume_set",
  "value": 0.70
}
```
Supported actions: `volume_set`, `volume_mute_toggle`, `play_pause`, `next_track`, `prev_track`.

### 3.4 Dock Apps Synchronization
```json
// Client Request
{ "type": "dock_get" }

// Host Response
{
  "type": "dock_list",
  "apps": [
    { "bundle_id": "com.apple.Safari", "name": "Safari", "is_active": true, "icon_base64": "..." },
    { "bundle_id": "com.apple.Music", "name": "Music", "is_active": false, "icon_base64": "..." }
  ]
}

// Switch App
{ "type": "app_activate", "bundle_id": "com.apple.Safari" }
```

### 3.5 System Power Controls
```json
{ "type": "power_command", "action": "lock_screen" }
{ "type": "power_command", "action": "display_sleep" }
{ "type": "power_command", "action": "system_sleep" }
{ "type": "power_command", "action": "shutdown" }
{ "type": "power_command", "action": "restart" }
```

---

## 4. Wake-on-LAN (WoL) Specification

When the Mac is in low-power sleep/standby mode (0.5W consumption), the iOS client can awaken the computer via UDP broadcast:

* **Broadcast Destination**: `255.255.255.255:9` and `255.255.255.255:7`
* **Packet Payload (102 Bytes)**:
  * 6 bytes synchronization sequence: `0xFF 0xFF 0xFF 0xFF 0xFF 0xFF`
  * 96 bytes: 16 consecutive repetitions of the 6-byte target network adapter MAC address
* **Burst Mode**: The iOS client broadcasts 3 consecutive bursts spaced 25ms apart to overcome Wi-Fi power-save sleep states.

---

## 5. SideStore Community Repository & Update Distribution

AirControl provides dual update channels:

1. **GitHub Releases & SideStore Community Source**:
   * Community source manifest: `https://raw.githubusercontent.com/emokeshi/Aircontrol/main/source.json`
   * One-click add source: `sidestore://source?url=https://raw.githubusercontent.com/emokeshi/Aircontrol/main/source.json`
   * In-place install: `sidestore://install?url=https://github.com/emokeshi/Aircontrol/releases/latest/download/AirControl.ipa`
2. **Local HTTP Update Server (Port 8923)**:
   * `GET /version.json`: Returns version information, release notes, and IPA download endpoints.
   * `GET /AirControl.ipa`: Delivers the binary IPA payload at local network speeds (50-100MB/s).
   * `GET /source.json`: SideStore / AltStore compatible source manifest.
   * `GET /`: Human-friendly web download and SideStore pairing page.
