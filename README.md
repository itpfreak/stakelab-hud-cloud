# Stake Lab HUD Cloud

Native macOS poker assistance co-pilot for Stake.com running on Floorp browser.
Cloud-model experiment using Gemini vision analysis for Stake.com. This is intentionally separate from the local Qwen project.

---

## Two Purpose-Built Modes

### 1. `StakeLabHUDCloud.app` (Solo / Off-Stream Grinder)
* **What it is:** Floating SwiftUI HUD window on your iMac desktop.
* **Safety:** Protected by macOS compositor exclusion (`NSWindow.sharingType = .none`).
* **Build:** `bash build_app.sh` → installs to `/Applications/StakeLabHUDCloud.app`.

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


## Cloud test setup

This project is separate from `stakelab-hud` and uses Gemini vision models. Put `GEMINI_API_KEY` in `~/stakelab-hud-cloud/.env` on the Mac; never commit that file. The default model is configurable with `GEMINI_MODEL` and currently defaults to `gemini-3.6-flash`.

Build:

```bash
cd ~/stakelab-hud-cloud && git pull && bash build_app.sh && open /Applications/StakeLabHUDCloud.app
```
