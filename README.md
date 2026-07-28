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

| One screen for practice | Recording is a mode |
| :---: | :---: |
| <img src="docs/images/studio.png" alt="The Atarang Studio with the Mixer stage, the practice tool chips, and the persistent transport showing an A–B loop" width="300"> | <img src="docs/images/studio-recording.png" alt="Atarang recording a take, with the microphone meter, levels, and one explanation above a dimmed chip row" width="300"> |
| The transport never scrolls: timeline, A–B loop, playback, and the tools that state their current value. | One red strip carries the meter, the levels, and what is locked — instead of a dozen disabled controls. |

Four **stages** share that one transport, and switching between them never stops
playback.

| Lyrics | Chords | Sheet |
| :---: | :---: | :---: |
| <img src="docs/images/stage-lyrics.png" alt="The Lyrics stage with the current line large and centred, the word being sung highlighted, and section markers between verses" width="230"> | <img src="docs/images/stage-chords.png" alt="The Chords stage showing E-flat major in bars four to a row, the current bar marked, and the next chord counted in beats" width="230"> | <img src="docs/images/stage-sheet.png" alt="The Sheet stage with chord symbols set over the words they land on" width="230"> |
| The word being sung, at arm's length. | The bar you are in, and the next chord in beats. | Chords over the words they land on. |

| Make the chords playable | The beat, found on the device |
| :---: | :---: |
| <img src="docs/images/tool-playability.png" alt="The Playability sheet with four simplification levels, tidying switches, and a capo suggestion" width="300"> | <img src="docs/images/tool-click.png" alt="The Click sheet showing a tempo of 96 BPM detected from the drums stem, the first downbeat, beats per bar, and a click that follows the song" width="300"> |
| Reduce the chart to triads or power chords, and let Atarang find the capo that turns barre chords into open ones. | Tempo, downbeat, and bar lines read off the drums — then driving the click, the count-in, and bar-snapped loops. |

| Choose the part you play | Build up repetitions |
| :---: | :---: |
| <img src="docs/images/tool-target.png" alt="The Target sheet offering Learn, Guide, and Play Along for the selected stem" width="300"> | <img src="docs/images/tool-reps.png" alt="The Reps sheet with a repetition target, a pause between passes, and a tempo ramp in percent and BPM" width="300"> |
| Hear your part alone, keep it quiet under the band, or mute it and take its place. | Count passes, breathe between them, and ramp from comfortable to full tempo. |

| Separate a song | App-level choices |
| :---: | :---: |
| <img src="docs/images/import.png" alt="The Atarang import screen listing Balanced 4-stem, Detailed 6-stem, and Vocals + Backing with their stems, speed, and download size" width="300"> | <img src="docs/images/settings.png" alt="Atarang Settings with recording defaults, a default separation, the opt-in online lyrics lookup, and About" width="300"> |
| Pick by outcome, with the stems, speed, download size, and device fit shown before you commit. | Recording defaults, the separation Studio offers first, the opt-in lyrics lookup, and the bundled notices. |

| Originals | Separated tracks | Performances |
| :---: | :---: | :---: |
| <img src="docs/images/library-originals.png" alt="Original songs in the Atarang Library" width="230"> | <img src="docs/images/library-separated.png" alt="Separated tracks in the Atarang Library" width="230"> | <img src="docs/images/library-performances.png" alt="Recorded performances in the Atarang Library" width="230"> |
| Reuse downloaded audio. | Reopen, play, record, or separate again. | Play, edit, share, or record another take. |

<sub>Captured in the iPhone 17 Pro Max simulator in dark mode. The loaded song is
a synthetic demo track — additive synthesis over an E♭-major progression at 96
BPM — so no copyrighted audio appears in the shots, and the key, tempo, chords,
and capo suggestion are all Atarang's own analysis of it.</sub>

## Make any song yours

Atarang is a personal iPhone practice app for musicians and singers. Paste a
YouTube URL, choose how you want the track separated, and let the phone create
synchronized stems locally. Turn down the part you want to perform, press play,
and practise against the rest of the band.

## Practise with purpose

Studio is one screen. A **transport** that never scrolls holds the timeline, the
A–B loop, and the controls you reach for with an instrument in your hands; a
**Stage** shows the song itself; and the practice tools are **chips** that state
their current value and open only themselves. Atarang remembers the stage,
playhead, selected target, mix, loop, speed, pitch, count-in, and saved sections
for each song, so the next session can pick up where the last one ended.

- **Master one phrase** — jump back five seconds, tap A then B on the transport
  to loop it, drag the handles on the timeline to fine-tune, and save multiple
  named sections for quick recall.
- **Slow down or change key** — adjust speed without changing pitch, or
  transpose the backing by semitones without changing tempo.
- **Build up repetitions** — choose a repetition target, add a pause between
  passes, and automatically ramp from a comfortable starting speed to the
  target tempo.
- **Practise your part three ways** — select any available vocal or instrument
  stem, then use **Learn** to hear it alone, **Guide** to keep it quietly in the
  mix, or **Play Along** to mute it and take its place.
- **Add a click and count-in** — let Atarang find the song's tempo and
  downbeats and follow them, or enter a BPM, use tap tempo, choose a
  subdivision, accent the downbeat, set the click level, and align it by hand.
- **Read the chords as you play** — work out the chord chart on the device, in
  bars or as a ribbon under a fixed "now" line, transposed to whatever key you
  have the backing in. Tap a bar to jump to it, hold and drag across bars to
  loop them, and hold one bar to fix a chord Atarang got wrong.
- **Make the chords playable** — reduce the chart to plain triads, open-position
  shapes, or power chords; hide slash chords and passing chords; and let Atarang
  suggest a capo, or a key to shift the whole song into, that turns barre chords
  into open ones. Every simplified chord is marked and the chord Atarang heard is
  a press away.
- **Read a chord sheet** — chord symbols placed over the words they land on,
  exactly where the lyrics carry word timings and estimated across the line where
  they do not, at whatever size reads from an arm's length.
- **Record a predictable loop take** — hear the count-in, record exactly one
  pass from A to B, and quickly compare the latest take with the reference.
- **Sing from synced lyrics** — paste the words or import an `.lrc`, time them
  by tapping once through the song, then tap a line to jump to it, hold one to
  loop it, or drag across several to set A–B. A sing-along mode puts the current
  line on screen at arm's length and keeps the display awake.

## Features

- **Up to six synchronized stems** — isolate vocals, drums, bass, guitar,
  piano, instrumental, or other parts depending on the selected model.
- **A persistent transport** — a waveform timeline with the playhead, the
  shaded A–B loop, draggable boundary handles, and saved-section marks, above
  play, record, back-five, A–B, speed, and key. It is always on screen while a
  song is loaded, and it is the only place that seeks.
- **A hands-on stem mixer** — set a level for every stem, mute or solo parts,
  and apply target-aware Learn, Guide, and Play Along presets.
- **Synced lyrics that do something** — paste plain words, import or export
  `.lrc` (line and word tags, and `[offset:]`), pull in a YouTube caption track,
  or search LRCLIB if you turn that on. Time a song by hand with tap-to-timestamp,
  nudge one line by a tenth of a second or shift them all, and turn `[Chorus]`
  markers into saved sections. The current line is large and centred, auto-scroll
  yields the moment you scroll yourself, and long instrumental stretches count
  you back in.
- **A chord chart worked out on the device** — bars four to a row with the
  current one marked and the next chord counted in beats, or a ribbon that
  scrolls under a fixed "now" line. The key is named, the chart follows the
  transport's transposition, chords Atarang is unsure of are dimmed rather than
  stated, and any chord can be corrected by holding its bar. Corrections survive
  running the analysis again. Nothing is downloaded and nothing leaves the
  device.
- **Chord shapes, a capo, and a sheet** — a chord box for every shape the song
  asks for, open and barre voicings for each, four levels of simplification from
  the full chart down to power chords, a capo search that scores every fret from
  0 to 7 by how much of the song it turns into open shapes, and the same answer
  as a key to shift the audio into. The Sheet stage sets the chords over the
  lyrics they land on. All of it is per song and none of it changes the stored
  chart.
- **A detected beat grid** — tempo, downbeats, and bar lines found from the
  drums, driving the click, the count-in, and A–B loops that snap to bars. A
  wrong tempo is usually one tap to fix, and a grid Atarang is unsure of is
  labelled rather than acted on.
- **Structured song practice** — loop and save difficult sections, control
  speed and key independently, add a count-in and a metronome that can follow
  the song, count repetitions, and ramp up to performance tempo.
- **Performance recording** — capture the microphone and live backing mix
  together, with independent microphone and backing levels; an active loop
  records one predictable pass from A to B.
- **Background-friendly sessions** — playback and recording continue when the
  app is backgrounded or the screen is locked, the lock screen and Control
  Centre show the loaded song, and headphone-remote play, pause, and skip-back
  work. The screen stays awake while a song is actually playing or recording.
- **A personal music library** — browse originals, separations, and
  performances; search, filter, inspect storage use, and reopen any mix.
- **Repeat without redownloading** — reuse a saved separation or run another
  model against an original already on the device.
- **Easy exports** — create an AAC/M4A performance and share performances or
  stems through AirDrop, Files, WhatsApp, and other compatible apps. An export
  keeps running if you open another song, and appears on its Library
  performance when it finishes.
- **Nothing half-saved** — downloads, separations, and takes are written aside
  and only enter the Library once complete and readable, so an interrupted
  operation leaves the previous state rather than a broken entry.
- **Settings that own app-level choices** — default microphone and backing
  levels for new takes, a remembered default separation, the opt-in online
  lyrics lookup, the app's version and source, and the bundled third-party
  notices.
- **Private by design** — extraction, separation, mixing, playback, and
  recording happen on the iPhone. There is no Atarang backend or account.

> [!TIP]
> Use headphones while recording for the cleanest take and to keep the backing
> track out of the microphone.

## How it works

1. **Paste** a `youtube.com` or `youtu.be` link.
2. **Choose** what you want out of it — Balanced 4-stem, Detailed 6-stem, or
   Vocals + Backing.
3. **Mix** the generated parts to make room for your voice or instrument.
4. **Play, record, and share** — your tracks and takes remain available in the
   on-device Library.

## Separation models

The app names these by outcome; the architecture behind each is secondary
detail.

| In the app | Model | Output | Availability | Best for |
| --- | --- | --- | --- | --- |
| **Balanced 4-stem** | HTDemucs | Vocals, drums, bass, other | Bundled | A balanced default with four-part control |
| **Detailed 6-stem** | HTDemucs 6-stem | Vocals, drums, bass, other, guitar, piano | 136 MB first-use download | Detailed instrument control on newer, high-memory devices |
| **Vocals + Backing** | MDX23C InstVoc HQ | Vocals, instrumental | 40 MB first-use download | A high-quality general vocal split, on high-memory devices |
| **Vocals + Backing, vocal-focused** | Kim Vocals | Vocals, instrumental | 67 MB first-use download | An alternative, vocal-focused separation, on high-memory devices |

Separation reads the song a block at a time rather than decoding all of it into
memory first, so a long track costs no more to hold than a short one. The
6-stem and the two vocal models still need substantial free memory for their
own tensors, and each is offered only when the device has the headroom for it;
the balanced 4-stem split runs everywhere.

Optional models are downloaded only when selected, verified against pinned
SHA-256 checksums, stored in Application Support, and excluded from iCloud
backup. An install is published atomically and recorded in a manifest, so a
download interrupted part way is re-fetched rather than reported as installed.
After a model has been downloaded, its separation work remains on-device.
Every installed model is listed with its size in **Settings → Downloads &
Models**, and can be removed there and downloaded again later.

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

Lyrics are the one place the app can talk to a service that is not YouTube, and
it is opt-in. **Online lyrics lookup is off by default.** With it turned on in
Settings, searching sends the song title — and the artist name, if you type one
— to [lrclib.net](https://lrclib.net), and nothing else. Nothing is sent while
it is off. Pasting lyrics, importing an `.lrc` file, and timing lines by tapping
all work with no network at all. Fetching a video's caption track uses the same
bundled `yt-dlp` and the same YouTube connection as the audio download.

The Library is stored locally on the device. It can permanently delete
originals, separations, and performances.

**Diagnostics stay anonymous.** The library report you can export from
**Settings → Diagnostics** lists folder identifiers, sizes, and what was wrong
with each entry. It never contains song titles, source URLs, or media
filenames.

## Storage and backup

Atarang checks that an operation can finish before it starts one. A download,
separation, take, or export that would not fit is refused with the amount of
space it is short by, rather than failing part way through — separated stems
are 32-bit float WAV, so a four-minute song costs roughly 340 MB at four stems
and 500 MB at six. **Settings → Storage** shows the totals by Originals,
Separations, Performances, Models, and temporary data.

What reaches iCloud is decided by whether anything could reproduce it, and by
one preference:

| Category | Backed up | Why |
| --- | --- | --- |
| Performances | Only if you turn it on | Your recordings. Nothing can reproduce them. |
| Practice state and analysis | Only if you turn it on | Loops, settings, lyrics, chords, beats, and your corrections. |
| Downloaded originals | Never | Re-fetchable from their source URL. |
| Separated stems | Never | Reproducible by separating again. |
| Optional models | Never | Re-downloadable and checksum-verified. |

**Backup of your own work is off by default.** Nothing you record or tune
leaves the device until you turn on *Back up my recordings and practice* in
**Settings → Privacy & Data**. The trade is worth stating plainly: while it is
off, restoring to a new device brings back no performances and no practice
state, and nothing can reproduce either. Turning it on applies to what is
already on the device, not just to what you record afterwards.

Atarang cannot switch iCloud Backup itself on or off — it only marks its own
files as included or excluded. To leave the app out of backups entirely, use
Settings › your name › iCloud › Manage Account Storage › Backups.

Because downloaded originals are a cache, their audio can be reclaimed from
**Settings → Storage** without losing the song: the practice settings, loops,
and analysis stay, and separating the song again downloads its audio.

At launch the app checks every library folder and sorts it into valid,
recoverable, incomplete, or unrecoverable. A folder whose description is
missing or damaged has it rebuilt from the files themselves where that can be
done reliably — the folder's own name is the entry's ID, the audio holds its
duration, and the set of stem files names the separation model that produced
them. A source URL and a title cannot be derived and are not invented, so a
recovered entry is titled as recovered and has no source. Anything that cannot
be rebuilt is moved to a quarantine folder rather than deleted or silently
skipped, and every finding is in the diagnostics report.

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
The same file ships in the app and is readable under **Settings › About ›
Third-Party Notices**.
