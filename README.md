# Sayso: open source macOs transcriber

Sayso is a macOS menu bar app for dictation. It uses whisper.cpp to detect the spoken language and transcribe audio locally after the initial model download.

## Install and use

1. Download the DMG from [GitHub Releases](../../releases), open it, and drag **VoiceKey.app** into Applications. This build appears as **VoiceKey** and requires an Apple silicon Mac running macOS 14 or later.
2. Open the app, click the waveform in the menu bar, and download a Whisper model.
3. Press **Option–Shift–Space** to start recording and grant microphone access when prompted. Press the shortcut again to stop and copy the transcript to the clipboard.

## Build from source

Install the Xcode Command Line Tools and run `./build.sh`. The script builds an ad hoc-signed app and bundles [whisper.cpp v1.8.4](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.8.4).
