# Ether Reader for Mac (SwiftUI)

A native macOS app that reads your words in your own voice. Voice generation runs on your Mac
(Apple Silicon) with the Qwen3-TTS model via MLX. No API key, no cloud voice service.

## Pages

- **Mic Test**: pick a microphone, watch a live level meter (green / yellow / red with a peak marker),
  get "too quiet / good / too loud (clipping)" advice, and record a 5-second test that plays back
  automatically. Warns when a Bluetooth mic (AirPods) is selected, since those sound crackly.
- **Record Voice**: read a script (editable), record up to 30 seconds, play it back,
  then press **Use this recording as my voice**. The script becomes the transcript automatically.
  Recordings are lossless (CAF / PCM). They aren't compressed, which avoids the crackle the browser recorder had.
- **Narrate**: paste a passage or open a .txt file, then press **Generate in my voice**. Long text is
  read in parts and joined together. You can play, pause, stop and seek, then save the narration as WAV.
- **Voice Engine**: one-button install of the Python voice engine. You can also pick the storage folder.
  The default is the **MAC Mini 2** external drive when it's connected (`/Volumes/MAC Mini 2/Ether Reader`).
  The engine, the model download, your voice and your narrations all live there.

## Build

Requirements: Apple Silicon Mac, macOS 14+, Xcode 15+, Python 3.10+ (3.11 recommended, from
python.org or `brew install python@3.11`).

**Easiest:** double-click `Build Ether Reader.command` (or run `bash "Build Ether Reader.command"`).
It builds the app, copies it to Applications and opens it.

**In Xcode:** open `EtherReader.xcodeproj`, choose the *EtherReader* scheme and *My Mac*, then press ⌘R.

Signing is "Sign to Run Locally", so no Apple developer account is needed.
The app asks for microphone permission the first time you test or record.

## First run

1. **Voice Engine**: press *Install voice engine* (internet needed, takes a few minutes).
2. **Mic Test**: choose your mic and record a test. Aim for "Good level".
3. **Record Voice**: record the script and use it as your voice.
4. **Narrate**: paste text and generate. The first time, the app downloads the model (several GB).

## Files

- `EtherReader/*.swift`: SwiftUI app (AVFoundation capture, metering, playback).
- `EtherReader/ether_tts.py`: voice worker the app runs with the engine's Python (keeps the model loaded).
- `EtherReader/requirements.txt`: Python packages installed by the app.
