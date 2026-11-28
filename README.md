<img src="Artwork/typewriter-macos-yellow-v2.svg" width="128" height="128" alt="Sayso’s yellow typewriter logo">

# Sayso

Sayso is a macOS menu bar app that types local Whisper dictation directly into the text field you’re using. Speech is processed on your Mac. The app keeps audio in memory and leaves your clipboard alone.

## Start dictating

1. Unzip **Sayso.app**, move it to **Applications**, and open it. Sayso runs on Apple silicon with macOS 14 or later.
2. Click the typewriter in the menu bar. Under **Speech model**, choose **Nava · فارسی** for Persian or **Whisper Large v3 Turbo** for multilingual dictation. Click **Download model**.
3. Click in a text field. With the default shortcut, double-tap **Right Shift** and hold the second press while speaking. On first use, allow **Accessibility** for keyboard entry and **Microphone** for recording, then return to the text field.
4. Pause briefly to type each phrase. Release **Right Shift** to finish and keep the text field focused until the floating indicator disappears. If you use a custom shortcut, **Settings → Recording** shows the gesture and how to stop.

Twelve bars in the floating indicator rise and fall with your voice. When you stop recording, the bars curl along a shared path into an eight-spoke ring. Each spoke then turns in place around its own long axis while Sayso finishes typing, then the indicator disappears. Your text field keeps focus. If another app owns the shortcut, use **Start dictation** in the popover or choose a different shortcut in Settings. Secure fields and apps that ignore synthetic Unicode keyboard events may not accept dictation.

## Models and settings

| Model | Download | When to choose it |
| --- | ---: | --- |
| Nava · فارسی | 574 MB | Default for new installations. Fine-tuned for Persian, with the recognition language fixed to Persian. |
| Whisper Large v3 Turbo | 574 MB | Multilingual dictation with automatic language detection. |

In **Settings → Models → Spoken language**, choose **Persian · فارسی** to skip language detection on multilingual models. Latency depends on the model, your Mac and how often you pause. Sayso reuses the loaded model and requests Metal acceleration when a GPU is available.

Downloads can be paused and resumed and are verified by size and SHA-256. **Unload** frees the model while keeping the download. **Move to Trash** removes it. Existing models and preferences use the original VoiceKey bundle identifier and the folder `~/Library/Application Support/VoiceKey/Models/`.

In **Settings → Recording**, choose **Toggle** to perform the same gesture to start and stop, or **Hold** to stop when you release the shortcut.

| Shortcut gesture | Toggle recording | Hold recording |
| --- | --- | --- |
| Tap | Press and release to start or stop. | Press to start immediately. |
| Hold | Hold for 0.35 seconds to start or stop. | Recording starts after 0.35 seconds. |
| Double tap | Tap twice to start or stop. | Tap once, then press and hold on the second tap. |

Every shortcut needs Command, Control, Option, or Shift. Tap requires a combination and excludes Shift plus a letter so you can type capitals. Hold and Double tap also accept an individual modifier, such as left Shift. Double tap follows your Mac’s double-click interval. Enable soft recording sounds for audible start and stop cues. The floating indicator respects Reduce Motion.

## Updates

Sayso checks the latest stable release on [GitHub](https://github.com/seenpeh/sayso/releases) at launch, when reopened and every 24 hours while running. You can also use **Settings → General → Check for Updates**. Select **Install … and restart** to download the release, verify its checksum and app signature, replace the current copy and reopen it. Install the app in a writable folder before updating.

If you still have a historical build numbered 1.2 through 1.9, download the [Sayso 1.2 release](https://github.com/seenpeh/sayso/releases/tag/v1.2.0) manually once. Those builds compare version numbers and may skip this update.

## Build and release

Install the Xcode Command Line Tools and run this on an Apple silicon Mac.

```sh
./build.sh
```

To publish an update, bump the version and build number in `Resources/Info.plist`. Create a stable GitHub release with a matching numeric tag and attach the build as `Sayso-<version>-macOS-arm64.zip`. A DMG with the same base name and the app at its root also works. The updater selects the matching architecture and verifies the SHA-256 digest supplied by GitHub.

### Preserve Accessibility across updates

Release ZIPs require a code signing certificate. Use the same certificate for every release so macOS can recognize the same app across updates. A regular `./build.sh` app build can still use ad hoc signing for local development.

For releases without a paid Apple Developer account, open Keychain Access and choose **Certificate Assistant → Create a Certificate**. Select **Self Signed Root** and **Code Signing**. Keep the identity in your signing keychain and back up the certificate and private key securely. Run `security find-identity -p codesigning` and use the certificate’s SHA-1 fingerprint below.

```sh
SAYSO_SIGNING_IDENTITY="<certificate fingerprint>" ./build.sh "$PWD/Sayso-<version>-macOS-arm64.zip"
```

Set `SAYSO_SIGNING_KEYCHAIN` if the identity lives in a separate keychain. A self-signed release may require first-launch approval in Gatekeeper. When switching from an ad hoc release, macOS may ask you to grant Accessibility again once. If the old Sayso entry is stale, remove it and add the installed copy under **System Settings → Privacy & Security → Accessibility**. After migration, the updater requires incoming builds to satisfy the installed app’s signing requirement.

The runtime is [whisper.cpp v1.8.4](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.8.4). Weights come from [Nava GGML](https://huggingface.co/Nimruz/Nava-ggml) and the [multilingual Whisper collection](https://huggingface.co/ggerganov/whisper.cpp).
