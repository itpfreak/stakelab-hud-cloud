# StakeLab HUD & StakeStream Suite

Native macOS poker assistance co-pilot for Stake.com running on Floorp browser.
Zero cloud tokens, zero subscription, 100% free local execution via Apple Vision OCR and local Qwen 3 VL 8B on LM Studio.

---

## Two Purpose-Built Modes

### 1. `StakeLabHUD.app` (Solo / Off-Stream Grinder)
* **What it is:** Floating SwiftUI HUD window on your iMac desktop.
* **Safety:** Protected by macOS compositor exclusion (`NSWindow.sharingType = .none`).
* **Build:** `bash build_app.sh` → installs to `/Applications/StakeLabHUD.app`.

### 2. `StakeStream` (Live Broadcast / Headless Air-Gap)
* **What it is:** 100% headless background daemon. Stripped of all on-screen AppKit window code. Impossible to leak onto stream capture buffers.
* **Air-Gap Dashboard:** Serves a dark-mode mobile/desktop web UI at `http://<iMac-IP>:8765` for your Mac mini (3rd monitor) or iPhone.
* **OBS Scene Automation:** Connects to OBS WebSocket (`ws://127.0.0.1:4455`). Automatically freezes OCR on `BRB`/`Away`/`Starting Soon` scenes and auto-resumes on `Gameplay`/`Live` scenes.
* **AirPod Whisper:** Client-side Web Speech toggle on the web page whispers actions into your connected AirPod without routing through iMac broadcast audio.
* **Build & Run:**
  ```bash
  bash build_stream.sh
  ./StakeStream
  ```

---

## Build All
```bash
bash build_all.sh
```
