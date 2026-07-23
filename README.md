# Atarang

Atarang is a personal iPhone practice app. Paste a YouTube URL, choose a separation model, and the phone downloads its audio and separates it locally. The synchronized stems can then be mixed with independent volume and mute controls.

| Model | Stems | Delivery |
| --- | --- | --- |
| HTDemucs (default) | Vocals, drums, bass, other | Bundled Core ML model |
| HTDemucs 6-stem | Vocals, drums, bass, other, guitar, piano | 136 MB first-use download |
| MDX23C InstVoc HQ | Vocals, instrumental | 40 MB first-use download |
| Kim Vocals | Vocals, instrumental | 67 MB first-use download |

Optional models are downloaded only when selected, verified with pinned SHA-256 checksums, stored in Application Support, and excluded from iCloud backup. Separation remains on-device after the model download.

While the stems play, tap the red record button to capture your microphone and the live backing mix together. Playback and recording continue when Atarang is backgrounded or the screen locks. After stopping, Atarang exports an AAC/M4A performance that can be shared to WhatsApp, Files, AirDrop, and other compatible apps. Headphones are recommended to prevent the backing track from bleeding into the microphone.

The **History** tab keeps an on-device library of separated songs and recorded performances. It can be searched or filtered, shows duration and storage use, and supports playback, reopening the mixer, recording another take, sharing stems or performances, and permanent deletion. Media made by older builds is discovered automatically when its files are still present.

There is no backend or companion service. Network access is used to fetch YouTube metadata and audio and, on first use, the selected optional model. A pinned `yt-dlp` Python zipapp is bundled with Atarang; extraction, separation, and playback happen entirely on the iPhone.

## Install

1. Open `Atarang.xcodeproj` in Xcode and let Swift Package Manager resolve its dependencies.
2. Connect and unlock your iPhone, trust the Mac if prompted, and select it as the run destination.
3. Press **Run**.
4. Paste a YouTube URL, choose a model, tap **Create stems**, and keep Atarang open until separation finishes.

The project uses automatic signing with development team `A8L3M4746U`. The bundled default FP16 model is about 233 MB before Xcode compilation, and processing is compute intensive; recent iPhones will work best. The project pins bundled `yt-dlp` version `2026.07.04` and verifies its SHA-256 checksum before use.

Only download audio you have permission to use and follow YouTube's terms. This personal sideloaded build is not designed or suitable for App Store distribution.

## Third-party software

- Hybrid Transformer Demucs and its pretrained weights, © Meta Platforms, Inc., MIT License.
- HTDemucs Core ML conversion, © 2026 Dejan Nikolic, MIT License.
- ONNX Runtime, © Microsoft Corporation, MIT License.
- ZIPFoundation, © 2017–2025 Thomas Zoechling, MIT License.
- Optional model conversions and weights are attributed in the third-party notices.
- YoutubeDL-iOS, © 2020 Changbeom Ahn, MIT License.

See `THIRD_PARTY_LICENSES.md` for notices.
