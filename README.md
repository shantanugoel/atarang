# Atarang

Atarang is a personal iPhone practice app. Paste a YouTube URL and the phone downloads its audio, separates it locally into vocals, drums, bass, and other with HTDemucs/Core ML, then plays the four synchronized stems with independent volume and mute controls.

There is no backend or companion service. Network access is used only to fetch YouTube metadata and audio. A pinned `yt-dlp` Python zipapp is bundled with Atarang; extraction, separation, and playback happen entirely on the iPhone.

## Install

1. Open `Atarang.xcodeproj` in Xcode and let Swift Package Manager resolve its dependencies.
2. Connect and unlock your iPhone, trust the Mac if prompted, and select it as the run destination.
3. Press **Run**.
4. Paste a YouTube URL, tap **Create four stems**, and keep Atarang open until separation finishes.

The project uses automatic signing with development team `A8L3M4746U`. The bundled FP16 model is about 233 MB before Xcode compilation, and processing is compute intensive; recent iPhones will work best. The project pins bundled `yt-dlp` version `2026.07.04` and verifies its SHA-256 checksum before use.

Only download audio you have permission to use and follow YouTube's terms. This personal sideloaded build is not designed or suitable for App Store distribution.

## Third-party software

- Hybrid Transformer Demucs and its pretrained weights, © Meta Platforms, Inc., MIT License.
- HTDemucs Core ML conversion, © 2026 Dejan Nikolic, MIT License.
- YoutubeDL-iOS, © 2020 Changbeom Ahn, MIT License.

See `THIRD_PARTY_LICENSES.md` for notices.
