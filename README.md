<div align="center">
  <img src="Atarang/Assets.xcassets/AppIcon.appiconset/Atarang-AppIcon.png" alt="Atarang app icon" width="150">
  <h1>Atarang</h1>
  <h3>Your song. Your part.</h3>
  <p>
    Turn a YouTube track into a private, on-device practice studio.<br>
    Separate the music, shape the mix, record your performance, and keep every
    take close at hand.
  </p>
  <p>
    <img src="https://img.shields.io/badge/iOS-17%2B-000000?style=flat-square&logo=apple" alt="iOS 17+">
    <img src="https://img.shields.io/badge/UI-SwiftUI-5C2D91?style=flat-square" alt="SwiftUI">
    <img src="https://img.shields.io/badge/Separation-Core%20ML-6C5CE7?style=flat-square" alt="Core ML">
    <img src="https://img.shields.io/badge/Processing-On--device-20BF6B?style=flat-square" alt="On-device processing">
  </p>
</div>

## Screenshots

| Start a session | Mix and record |
| :---: | :---: |
| <img src="docs/images/studio.jpg" alt="Atarang Studio ready for a YouTube URL" width="320"> | <img src="docs/images/mixer.jpg" alt="Atarang stem mixer and recording controls" width="320"> |
| Paste a link and choose a separation style. | Shape every stem and balance the microphone and backing track. |

| Loop, transpose, and save | Practise with structure |
| :---: | :---: |
| <img src="docs/images/practice-loop-and-pitch.jpg" alt="Atarang Practice workspace with rewind, speed, pitch, A–B loop, and saved-section controls" width="320"> | <img src="docs/images/practice-metronome-and-target.jpg" alt="Atarang Practice workspace with manual metronome, practice-target presets, and count-in controls" width="320"> |
| Isolate a phrase, change its key, and keep useful sections. | Align a click, choose your part, and move from learning to playing along. |

| Originals | Separated tracks | Performances |
| :---: | :---: | :---: |
| <img src="docs/images/library-originals.jpg" alt="Original songs in the Atarang Library" width="240"> | <img src="docs/images/library-separated.jpg" alt="Separated tracks in the Atarang Library" width="240"> | <img src="docs/images/library-performances.jpg" alt="Recorded performances in the Atarang Library" width="240"> |
| Reuse downloaded audio. | Reopen, play, record, or separate again. | Play, edit, share, or record another take. |

## Make any song yours

Atarang is a personal iPhone practice app for musicians and singers. Paste a
YouTube URL, choose how you want the track separated, and let the phone create
synchronized stems locally. Turn down the part you want to perform, press play,
and practise against the rest of the band.

## Practise with purpose

Switch from **Mix** to **Practice** without interrupting playback. Atarang
remembers the practice workspace, playhead, selected target, mix, loop, speed,
pitch, count-in, and saved sections for each song, so the next session can pick
up where the last one ended.

- **Master one phrase** — jump back five seconds, mark and fine-tune an A–B
  loop, then save multiple named sections for quick recall.
- **Slow down or change key** — adjust speed without changing pitch, or
  transpose the backing by semitones without changing tempo.
- **Build up repetitions** — choose a repetition target, add a pause between
  passes, and automatically ramp from a comfortable starting speed to the
  target tempo.
- **Practise your part three ways** — select any available vocal or instrument
  stem, then use **Learn** to hear it alone, **Guide** to keep it quietly in the
  mix, or **Play Along** to mute it and take its place.
- **Add a manual click and count-in** — enter a BPM or use tap tempo, choose a
  subdivision, accent the downbeat, set the click level, and align it with the
  song. The metronome is manually aligned rather than tempo-detected.
- **Record a predictable loop take** — hear the count-in, record exactly one
  pass from A to B, and quickly compare the latest take with the reference.

## Features

- **Up to six synchronized stems** — isolate vocals, drums, bass, guitar,
  piano, instrumental, or other parts depending on the selected model.
- **A hands-on stem mixer** — set a level for every stem, mute or solo parts,
  and apply target-aware Learn, Guide, and Play Along presets.
- **Structured song practice** — loop and save difficult sections, control
  speed and key independently, add a count-in and manually aligned metronome,
  count repetitions, and ramp up to performance tempo.
- **Performance recording** — capture the microphone and live backing mix
  together, with independent microphone and backing levels; an active loop
  records one predictable pass from A to B.
- **Background-friendly sessions** — playback and recording continue when the
  app is backgrounded or the screen is locked.
- **A personal music library** — browse originals, separations, and
  performances; search, filter, inspect storage use, and reopen any mix.
- **Repeat without redownloading** — reuse a saved separation or run another
  model against an original already on the device.
- **Easy exports** — create an AAC/M4A performance and share performances or
  stems through AirDrop, Files, WhatsApp, and other compatible apps.
- **Private by design** — extraction, separation, mixing, playback, and
  recording happen on the iPhone. There is no Atarang backend or account.

> [!TIP]
> Use headphones while recording for the cleanest take and to keep the backing
> track out of the microphone.

## How it works

1. **Paste** a `youtube.com` or `youtu.be` link.
2. **Choose** a 2-, 4-, or 6-stem separation style.
3. **Mix** the generated parts to make room for your voice or instrument.
4. **Play, record, and share** — your tracks and takes remain available in the
   on-device Library.

## Separation models

| Model | Output | Availability | Best for |
| --- | --- | --- | --- |
| **HTDemucs** | Vocals, drums, bass, other | Bundled | A balanced default with four-part control |
| **HTDemucs 6-stem** | Vocals, drums, bass, other, guitar, piano | 136 MB first-use download | Detailed instrument control on newer, high-memory devices |
| **MDX23C InstVoc HQ** | Vocals, instrumental | 40 MB first-use download | A high-quality general vocal split |
| **Kim Vocals** | Vocals, instrumental | 67 MB first-use download | An alternative, vocal-focused separation |

Optional models are downloaded only when selected, verified against pinned
SHA-256 checksums, stored in Application Support, and excluded from iCloud
backup. After a model has been downloaded, its separation work remains
on-device.

## Install on your iPhone

Atarang is currently a personal, sideloaded project rather than an App Store
release.

### Requirements

- A Mac with Xcode and an iOS 17 SDK
- [Git LFS](https://git-lfs.com/) for the bundled HTDemucs model weights
- An iPhone or iPad running iOS 17 or later
- An Apple Developer account for device signing
- A recent iPhone recommended for faster separation and the 6-stem model

### Clone with the model weights

The bundled HTDemucs model stores its 190 MB weight blob in Git LFS. Install
and enable Git LFS **before cloning**:

```sh
brew install git-lfs
git lfs install
git clone <repository-url>
cd Atarang
```

`git lfs install` is a one-time setup for your user account. After that, normal
Git clones automatically download LFS files. Git itself cannot install Git LFS,
so each developer must complete this setup once.

If you cloned Atarang before installing Git LFS, fetch the model weights
manually from the repository root:

```sh
git lfs install
git lfs pull
```

Verify that the model blob was downloaded before building:

```sh
wc -c < Atarang/HTDemucs_CoreML_FP16.mlpackage/Data/com.apple.CoreML/weights/weight.bin
```

The command should print `190099328`. A 134-byte file beginning with
`version https://git-lfs.github.com/spec/v1` is only an unresolved LFS pointer.
Building with that pointer causes Core ML to fail with “Failed to build the
model execution plan … error code: -5.” After fetching the real weights, clean
the Xcode build folder and rebuild the app.

### Build and run

1. Open `Atarang.xcodeproj` in Xcode and let Swift Package Manager resolve the
   dependencies.
2. Select the **Atarang** target and open **Signing & Capabilities**.
3. Choose your Apple Developer team. If needed, replace the existing bundle
   identifier with one that belongs to your account.
4. Connect and unlock your iPhone, trust the Mac if prompted, and select the
   device as the run destination.
5. Press **Run**, then paste a YouTube URL and tap **Create stems**.

Keep Atarang open while separation is running. The bundled default FP16 model
is approximately 233 MB before Xcode compilation, and the work is compute
intensive.

## Privacy and network use

Atarang has no backend or companion service. Network access is used only to
fetch YouTube metadata and audio and, on first use, the selected optional
model. A pinned `yt-dlp` Python zipapp is bundled with the project; the current
checked-in version is `2026.07.04` and its SHA-256 checksum is verified before
use.

The Library is stored locally on the device. It can permanently delete
originals, separations, and performances.

> [!IMPORTANT]
> Only download audio you have permission to use and follow YouTube's terms.
> This personal sideloaded build is not designed or suitable for App Store
> distribution.

## Third-party software

- Hybrid Transformer Demucs and its pretrained weights, © Meta Platforms,
  Inc., MIT License.
- HTDemucs Core ML conversion, © 2026 Dejan Nikolic, MIT License.
- ONNX Runtime, © Microsoft Corporation, MIT License.
- ZIPFoundation, © 2017–2025 Thomas Zoechling, MIT License.
- Optional model conversions and weights are attributed in the third-party
  notices.
- YoutubeDL-iOS, © 2020 Changbeom Ahn, MIT License.

See [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md) for complete notices.
