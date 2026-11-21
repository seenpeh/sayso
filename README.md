# Sayso

Sayso is a macOS menu bar app that types local Whisper dictation directly into the text field you’re using. Speech is processed on your Mac. The app keeps audio in memory and leaves your clipboard alone.

## Start dictating

1. Quit the previous VoiceKey version if it’s running. Unzip **Sayso.app**, move it to **Applications**, and open it. This build supports Apple silicon on macOS 14 or later.
2. Click the waveform in the menu bar, choose **Persian Base · فارسی** and click **Download**. Existing installations keep their previous model selection.
3. Click where you want to type and press **Option–Shift–Space**. On first use, allow **Accessibility** for keyboard entry and **Microphone** for recording. Return to the text field and press the shortcut again if prompted.
4. Speak naturally. A brief pause sends each phrase for recognition. During continuous speech, Sayso also processes short sections. Press the shortcut again, or click the recording icon in the menu bar, to finish the last phrase. Keep the destination field focused until typing finishes.

The menu bar shows listening and finishing states. If another app owns the shortcut, use **Start dictation** in the popover or choose a different shortcut in Settings. Secure fields and apps that ignore synthetic Unicode keyboard events may not accept dictation.

## Models and settings

| Model | Download | When to choose it |
| --- | ---: | --- |
| Nava · فارسی | 574 MB | Persian-tuned Whisper Large v3 Turbo, using the publisher’s Q5_0 GGML weights. |
| Persian Base · فارسی | 82 MB | Default for new installations. Fine-tuned for Persian, with the recognition language fixed to Persian. |
| Whisper Tiny · Compact / Whisper Tiny | 32 / 78 MB | Fast multilingual dictation. Compact uses quantized weights. |
| Whisper Base / Small / Medium | 60 / 190 / 539 MB | Multilingual alternatives for different speed and accuracy needs. |
| Whisper Large v3 Turbo | 574 MB | A larger multilingual model for more demanding speech. |

In **Settings → Models → Spoken language**, choose **Persian · فارسی** to skip language detection on multilingual models. Latency depends on the model, your Mac and how often you pause. Sayso reuses the loaded model and requests Metal acceleration when a GPU is available.

Downloads can be paused and resumed and are verified by size and SHA-256. **Unload** frees the model while keeping the download. **Move to Trash** removes it. Existing models and preferences use the original VoiceKey bundle identifier and the folder `~/Library/Application Support/VoiceKey/Models/`.

In **Settings → Recording**, choose toggle or hold for your key combination, hold left Shift briefly to talk, or double-tap left Shift to start and stop. Enable soft sounds for audible start and stop cues. The recording icon pulses unless Reduce Motion is enabled.

## Updates

Sayso checks the latest stable release on [GitHub](https://github.com/seenpeh/sayso/releases) at launch, when reopened and every 24 hours while running. You can also use **Settings → General → Check for Updates**. Select **Install … and restart** to download the release, verify its checksum and app signature, replace the current copy and reopen it. Install the app in a writable folder before updating.

## Build and release

Install the Xcode Command Line Tools and run this on an Apple silicon Mac.

```sh
./build.sh "$PWD/Sayso-1.5-macOS-arm64.zip"
```

To publish an update, bump the version and build number in `Resources/Info.plist`. Create a stable GitHub release with a matching numeric tag such as `v1.5` and attach the build as `Sayso-1.5-macOS-arm64.zip`. A DMG with the same base name and the app at its root also works. The updater selects the matching architecture and verifies the SHA-256 digest supplied by GitHub. The local build is ad hoc signed.

The runtime is [whisper.cpp v1.8.4](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.8.4). Weights come from [Persian Base GGML](https://huggingface.co/armantee/whisper-base-persian-ggml) and the [multilingual Whisper collection](https://huggingface.co/ggerganov/whisper.cpp).
