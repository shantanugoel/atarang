# Studio Redesign and Song Analysis Plan

Covers the Studio layout redesign, the audio-layer work it depends on, synced
lyrics, and guitar chord detection with optional simplification.

This plan supersedes `PRACTICE_TOOLS_PLAN.md` Phase 3 (analysis-assisted
practice) and implements `IMPROVEMENTS_PLAN.md` items 14, 17, and parts of 12
and 19 as a consequence of its structure rather than as separate work.

## Status

- [ ] Not started
- [~] In progress
- [x] Complete
- [!] Blocked or needs a decision

Update the checkboxes as work progresses. Each phase must leave the app in a
shippable state; later phases must not be required to make earlier ones useful.

## Product direction

Studio becomes **one song screen** rather than a Mix/Practice pair:

- A **persistent transport** that never scrolls — timeline with A/B and section
  markers, plus play, record, loop, speed, and key.
- A **Stage** that swaps between **Lyrics**, **Chords**, **Sheet**, and
  **Mixer**.
- **Practice tools as stateful chips** that display their current value and open
  a focused sheet. This replaces the always-expanded Practice section stack.

Lyrics and chords are practice instruments, not decoration: tapping a lyric line
seeks, dragging across lines or bars sets a loop, and chord display follows the
player's transposition.

## Decisions taken

- [x] **Online lyrics lookup (LRCLIB): yes, opt-in.** Off by default, disclosed
      in Settings, README privacy section updated when it ships.
- [x] **Practice disappears as a destination.** Its tools become chips. This is
      the largest visible change to existing muscle memory and is accepted.
- [x] **Transcription: `SFSpeechRecognizer` as the floor, Whisper as an optional
      download.** Whisper follows the existing `ModelAssetStore` pattern.
- [!] **Chord-analysis design target: assumed 4-stem, with 6-stem as a quality
      bonus.** Needs confirmation. If 6-stem is the common case, Phase 5
      feature extraction should be tuned against guitar and piano stems
      instead of treating them as optional inputs.

## Guiding principles

Inherited from `PRACTICE_TOOLS_PLAN.md`, plus:

- Every analysis result is correctable, and user corrections survive
  re-analysis.
- Never present a guess as a fact. Show confidence; label transcribed and
  simplified output.
- Analysis never blocks playback, recording, or practice.
- Every ML-free capability ships before any capability that needs a model.
- Timestamps are always in source-song seconds, so they stay correct under
  speed and pitch changes.
- Analysis attaches to the **Original**, not to a separation, so it survives
  re-separating with a different model.

---

## Phase 0 — Audio foundation

**Goal:** Make the audio layer able to drive frame-accurate visuals and frequent
seeking, with the existing UI still in place so each change is verifiable
against known-good behaviour.

### Work

- [ ] Add `StemPlayer.currentPosition() -> TimeInterval` computed on demand from
      `lastRenderTime`, falling back to `playbackState.position` when paused.
- [ ] Subtract `AVAudioSession.outputLatency + ioBufferDuration` from the
      computed position so visuals match what is heard on Bluetooth routes.
- [ ] Stop driving UI from the 10 Hz `Timer` alone; expose a display-rate path
      suitable for `CADisplayLink` or `TimelineView(.animation)`.
- [ ] Fix the existing run-loop-mode defect: the position timer must continue
      firing during scroll tracking.
- [ ] Apply the existing 2-second persistence throttle to every
      `persistPracticeSettings()` path; `seek` must not perform two
      `UserDefaults` JSON encodes per tap.
- [ ] Pre-render a single metronome click buffer at load and schedule it per
      click in a rolling window, instead of synthesizing the whole remaining
      song's click track on the main actor inside `play()`.
- [ ] Migrate `StemPlayer` to `@Observable` so SwiftUI tracks per-property
      instead of invalidating on every published change.
- [ ] Replace the per-sample RMS loop in `meterLevel` with `vDSP_rmsqv`.
- [ ] Guard the timing-stem path: if the first active stem schedules zero
      frames, fall back to another stem rather than silently losing position
      updates and loop completions.
- [ ] Add `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` support for lock
      screen and headphone-remote play/pause/seek.
- [ ] Add `isIdleTimerDisabled` handling, scoped to full-screen practice modes.
- [ ] Extend unit coverage: latency-compensated position, throttled persistence,
      click scheduling, timing-stem fallback.

### Acceptance criteria

- [ ] The playhead continues updating while the user scrolls.
- [ ] Visual position matches audible position within 30 ms on wired output and
      within 50 ms on Bluetooth.
- [ ] Ten consecutive seeks produce no audible hitch and no more than one
      settings write per second.
- [ ] Lock screen shows the current song; headphone play/pause works.
- [ ] No regression in playback, looping, recording, export, or route handling
      on the physical-device matrix.

### Open decision

- [!] Should `supportedRateRange` extend above 1.0? Practice above original
      tempo is a common late-stage request and the tempo ramp currently cannot
      target it.

---

## Phase 1 — Studio layout

**Goal:** Replace the Mix/Practice split with the transport + Stage + chips
structure, creating the space lyrics and chords need. No new analysis.

### 1. Persistent transport

- [ ] Build a two-row transport pinned via `safeAreaInset`.
- [ ] Row 1: scrubbable timeline with playhead, A/B markers, shaded loop region,
      and saved-section ticks.
- [ ] Render a static waveform overview once at load from the summed stems;
      cache it beside the track.
- [ ] Row 2: back-5, play/pause, record, loop toggle, speed chip, key chip.
- [ ] Delete the two in-scroll position sliders; the transport is the single
      source of truth for seeking.

### 2. Stage container

- [ ] Add a Stage area with a segmented and swipeable selector.
- [ ] Move the existing stem mixer into the **Mixer** stage unchanged.
- [ ] Add placeholder **Lyrics** and **Chords** stages with their empty states.
- [ ] Extend `StudioWorkspace` to `{lyrics, chords, sheet, mixer}`; bump
      `SongPracticeSettings.currentSchemaVersion` to 3 and migrate both existing
      values to `.mixer`.

### 3. Practice tools as chips

- [ ] Build a horizontally scrolling chip row that displays each tool's current
      value.
- [ ] Chips: Loop, Speed, Key, Target, Click, Reps, Sections, Count-in.
- [ ] Each chip opens a medium-detent sheet containing only that tool.
- [ ] Remove `practiceWorkspace` and its always-expanded sections.

### 4. Recording as a mode

- [ ] Consolidate mic level, backing level, live meter, and echo-cancellation
      status into the transport during recording.
- [ ] Replace scattered disabled states with one clear mode explanation.
- [ ] Surface loop-take comparison (Reference / Latest Take) in the same place.

### 5. Chrome and navigation

- [ ] Restore the system navigation bar; delete the hand-drawn `mixerHeader`.
- [ ] Move New Song, Share, Separate Again, Reset Practice Settings, and future
      analysis actions into a toolbar menu.
- [ ] Add haptics on A/B set, loop wraparound, count-in ticks, and repetition
      target reached.
- [ ] Auto-dismiss the notice banner.

### 6. Adaptive layout

- [ ] Regular width: Stage left, tool inspector right, transport full width.
- [ ] Landscape iPhone: same split with the chip row folded into the transport.

### 7. Decomposition

- [ ] Split `ContentView.swift` into `TransportBar`, `StageContainer`,
      `ToolChipRow`, `ImportView`, and `RecordingMode`.

### Acceptance criteria

- [ ] A first-time user can set an A–B loop, slow it down, and repeat it without
      opening more than one sheet.
- [ ] Every capability previously in Mix or Practice is reachable within one
      additional interaction.
- [ ] The playhead and transport are visible at all times when a song is loaded.
- [ ] Dynamic Type at accessibility sizes, VoiceOver reading order, and 44pt
      targets are preserved throughout.
- [ ] Existing per-song persisted state loads correctly after the schema bump.

---

## Phase 2 — Analysis infrastructure

**Goal:** One serialized place for long-running work, and song-scoped storage,
before any analysis feature exists.

### Work

- [ ] Add an `AnalysisQueue` actor serializing separation, transcription, and
      chord/beat analysis. One job at a time, globally.
- [ ] Block all analysis while `StemPlayer.isRecording`.
- [ ] Run jobs at `.utility` QoS; make every job cancellable and idempotent, and
      discard partial output on failure.
- [ ] Report all jobs through one shared progress surface.
- [ ] Gate model-backed jobs on `ModelMemoryBudget`, matching the `htdemucs6s`
      treatment.
- [ ] Define song-scoped storage: `lyrics.json`, `chords.json`, `beats.json` in
      `Application Support/Originals/<originalID>/`, written through
      `LibraryMetadata`.
- [ ] Resolve storage from `TrackMetadata.sourceOriginalID`, falling back to the
      track folder when the original has been deleted.
- [ ] Add an `analysisVersion` constant so improving an algorithm invalidates
      cached results, mirroring `separationCacheVersion`.
- [ ] Extend Library storage accounting to cover analysis artifacts and
      downloaded analysis models.

### Acceptance criteria

- [ ] Two analysis requests never run concurrently, and neither runs during a
      take.
- [ ] Cancelling a job leaves no partial artifact and is not reported as an
      error.
- [ ] Re-separating a song with a different model preserves its lyrics, chords,
      and beat grid.

---

## Phase 3 — Synced lyrics, without any model

**Goal:** A complete, useful synced-lyrics feature with no ML and no new
accuracy risk.

### 1. Model and storage

- [ ] Add `Lyrics.swift`: `LyricWord`, `LyricLine`, `LyricsSource`, `SongLyrics`.
- [ ] Persist through the Phase 2 song-scoped storage.

### 2. Reading view

- [ ] Current line large and centred; two lines above and below dimmed.
- [ ] Auto-scroll follows the playhead; user scroll suspends it and shows a
      "Back to playhead" pill.
- [ ] Word-level fill sweep when word timings are present.
- [ ] Tap a line to seek to it.
- [ ] Long-press a line to loop it; drag across lines to set A–B.
- [ ] Vocal-entry countdown after instrumental gaps longer than four seconds.
- [ ] Render section labels inline and offer to populate Saved Sections from
      them.
- [ ] Publish only `currentLineIndex` so a line change redraws two rows, not the
      tree.

### 3. Sing-along mode

- [ ] Full-screen presentation: large type, chords hidden, reduced transport,
      idle timer disabled, landscape supported.
- [ ] Small unobtrusive mic meter while recording.

### 4. Input and editing

- [ ] Paste plain lyrics.
- [ ] Import and export `.lrc`, including `[mm:ss.xx]` line tags,
      `<mm:ss.xx>` word tags, and `[offset:]`.
- [ ] Accept `.lrc` from the document picker and the share sheet.
- [ ] Tap-to-timestamp mode: play, tap `Set` per line, advance automatically.
- [ ] Per-line nudge ±0.1 s and a global offset slider ±2 s.
- [ ] Mark every edited line `isUserEdited`; never overwrite on re-analysis.

### 5. YouTube captions

- [ ] Extend the existing `yt_dlp(argv:)` call with `--write-subs
      --write-auto-subs --sub-langs --sub-format vtt --skip-download`.
- [ ] Parse WebVTT cues into `LyricLine`s, marked `.youtubeCaptions`, low
      confidence, fully editable.
- [ ] Offer them with a preview rather than applying them silently.

### 6. LRCLIB lookup (opt-in)

- [ ] Add a Settings toggle, off by default, with a clear statement of what is
      sent.
- [ ] Look up by title, artist, and duration; present candidates for
      confirmation.
- [ ] Update the README privacy section when this ships.

### Acceptance criteria

- [ ] Line-level sync is accurate to within ±150 ms after a single
      tap-to-timestamp pass.
- [ ] A song with no network access can be fully lyric-synced by hand.
- [ ] Auto-scroll remains smooth at 0.5× speed and at ±12 semitones.
- [ ] Transcribed or imported lyrics are visibly labelled until edited.
- [ ] Lyric-range looping produces the same result as setting A–B manually.

---

## Phase 4 — Beat and downbeat grid

**Goal:** A musical time grid, with no model download. Upgrades the metronome and
looping as well as enabling chords.

### Work

- [ ] Compute a spectral-flux onset envelope from the drums stem.
- [ ] Estimate tempo by autocorrelation or comb filtering, with a log-normal
      prior centred near 120 BPM.
- [ ] Track beats with Ellis-style dynamic programming.
- [ ] Estimate the downbeat phase from bass-onset energy and chord-change
      likelihood.
- [ ] Store `BeatGrid` as an explicit beat list so tempo drift is representable.
- [ ] Make BPM, first-downbeat offset, and beats-per-bar user-editable, with
      `isUserEdited` respected on re-analysis.
- [ ] Auto-align the metronome from the grid, replacing manual alignment as the
      default while keeping manual override.
- [ ] Snap A–B loop boundaries to bar lines, with a modifier to set them freely.
- [ ] Derive count-in from the detected tempo and schedule it in the audio graph
      instead of `Task.sleep`.
- [ ] Express the tempo ramp in BPM as well as percentage.
- [ ] Detect and report low-confidence grids rather than showing a wrong tempo.

### Acceptance criteria

- [ ] On steady-tempo material the grid is within ±15 ms of hand-tapped beats.
- [ ] A wrong grid can be corrected in under three interactions.
- [ ] Bar-snapped looping selects musically sensible boundaries.
- [ ] The count-in no longer drifts and matches the song's tempo.
- [ ] Analysis failure leaves the manual metronome fully functional.

---

## Phase 5 — Chord detection, bundled tier

**Goal:** Useful chords with no download, honest about accuracy.

### 1. Feature extraction

- [ ] Build the analysis mix: `0.8·bass + other + guitar + piano`, excluding
      vocals and drums; record `sourceStemSet` with the result.
- [ ] Resample to 22.05 kHz mono.
- [ ] Compute a harmonic pitch-class profile with overtone suppression.
- [ ] Compute a separate bass chroma from the bass stem over ~40–250 Hz.
- [ ] Average chroma within beats from the Phase 4 grid.

### 2. Classification

- [ ] Define templates for `{maj, min}` first, extending to `{dom7, min7, maj7,
      sus4, dim}` plus no-chord.
- [ ] Score frames by cosine similarity, with a bass term rewarding root and
      inversion matches.
- [ ] Decode with an HMM: strong self-transition prior plus key-conditioned
      transition probabilities.
- [ ] Estimate key by Krumhansl–Schmuckler correlation, cross-checked against
      the decoded chord histogram.
- [ ] Emit `ChordSegment`s snapped to beats and bars.

### 3. Display

- [ ] Bar-grid view, four bars per row, section labels, current bar highlighted,
      auto-scrolling ahead of the playhead.
- [ ] Ribbon view scrolling under a fixed "now" line.
- [ ] Next-chord preview with a beat countdown.
- [ ] Tap a bar to seek; drag across bars to set a bar-snapped loop.
- [ ] Dim low-confidence chords; long-press to correct one.
- [ ] Transpose displayed chords by `player.pitchSemitones` so the chart always
      matches what is heard.
- [ ] Detect material the templates cannot model and say so, instead of
      displaying confident nonsense.

### Acceptance criteria

- [ ] Analysis of a 4-minute song completes in under 30 seconds without
      blocking playback.
- [ ] Chord display remains correct at every supported transposition.
- [ ] Any chord can be corrected, and corrections survive re-analysis.
- [ ] Unreliable results are labelled rather than shown as facts.

---

## Phase 6 — Simplification, capo, and the Sheet view

**Goal:** Make the chords playable by the person holding the guitar.

### Work

- [ ] Add a complexity level: **Full**, **Simple** (triads), **Beginner** (open
      shapes), **Power** (root and fifth). Persist per song.
- [ ] Add independent toggles: hide slash/inversions, merge repeated chords,
      hide sub-beat passing chords.
- [ ] Implement capo suggestion: search capo 0–7 against an open-shape
      vocabulary, scoring by easy-shape coverage and barre penalty.
- [ ] Mark every simplified chord; tap reveals the detected chord.
- [ ] Add reverse transposition: choose a playable key and shift the audio to
      match.
- [ ] Bundle a chord-shape database keyed by root and quality, with open and
      barre voicings.
- [ ] Add a fretboard diagram sheet and a chord-vocabulary strip for the song.
- [ ] Build the **Sheet** stage: chord symbols positioned over lyric syllables,
      exact with word-level timing and interpolated otherwise.

### Acceptance criteria

- [ ] Beginner level produces a chord set playable in open position, or states
      that it cannot.
- [ ] A capo suggestion, when accepted, yields chords that sound correct against
      the transposed backing.
- [ ] Simplified chords are always distinguishable from detected chords.
- [ ] The Sheet view is legible at arm's length while holding an instrument.

---

## Phase 7 — Chord detection, optional model tier

**Goal:** Higher accuracy and extended qualities for users who want them.

### Work

- [ ] Convert a CRNN or transformer chord model to ONNX or Core ML.
- [ ] Serve it through `ONNXModelSession` and `ModelAssetStore` with a pinned
      SHA-256, Application Support storage, and backup exclusion.
- [ ] Present it in outcome language: "Standard chords — bundled" versus
      "Detailed chords — extended qualities and slash chords".
- [ ] Support extended qualities and slash bass end to end through
      simplification and display.
- [ ] Re-run analysis on demand without discarding user corrections.

### Acceptance criteria

- [ ] The model tier measurably outperforms the bundled tier on a held-out set.
- [ ] Download, verification, and failure paths match the separation models.
- [ ] Removing the model returns the app to the bundled tier cleanly.

---

## Phase 8 — Lyric transcription

**Goal:** Generate timings from audio. Largest and riskiest; deliberately last.

### Work

- [ ] Render the vocals stem to 16 kHz mono for recognition.
- [ ] Baseline: `SFSpeechRecognizer` with `requiresOnDeviceRecognition`, chunked
      with overlap, using `SFTranscriptionSegment` timings.
- [ ] Optional: Whisper via `ModelAssetStore`, with word timings from
      cross-attention alignment.
- [ ] Behind `#available(iOS 26, *)`, prefer `SpeechAnalyzer` /
      `SpeechTranscriber` when present.
- [ ] Implement forced alignment: recognise, normalise both token sequences,
      align by Needleman–Wunsch or DTW, propagate timestamps to the user's
      lyrics, interpolate gaps, roll up to lines.
- [ ] Make "Sync my lyrics" — alignment against text the user already has — the
      default action, not raw transcription.
- [ ] Report per-line confidence and label output until edited.

### Acceptance criteria

- [ ] Forced alignment on a clean vocal stem reaches ±150 ms on at least 80% of
      lines for a representative set.
- [ ] Raw transcription is never presented as authoritative.
- [ ] Recognition failure leaves manual and imported lyrics untouched.
- [ ] Whisper is never required for any other feature to work.

---

## Delivery milestones

### Milestone A — Foundation
Phases 0 and 1. The audio layer can drive accurate visuals and frequent seeking,
and the Studio has somewhere to put lyrics and chords.

### Milestone B — Lyrics
Phases 2 and 3. A complete synced-lyrics feature with no model downloads.

### Milestone C — Chords
Phases 4, 5, and 6. Beat grid, bundled chord detection, simplification, capo
suggestion, and the Sheet view — still with no model downloads.

### Milestone D — Accuracy
Phases 7 and 8. Optional models for users who want better chords and automatic
lyric timing.

---

## Data model reference

```swift
// Lyrics.swift
struct LyricWord: Codable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

struct LyricLine: Codable, Identifiable, Sendable {
    let id: UUID
    var text: String
    var start: TimeInterval?        // nil ⇒ unsynced
    var end: TimeInterval?
    var words: [LyricWord]?
    var sectionLabel: String?
    var confidence: Float?
    var isUserEdited: Bool
}

enum LyricsSource: Codable, Sendable {
    case manual
    case importedLRC
    case youtubeCaptions
    case onlineDatabase(name: String)
    case transcribed(engine: String, version: Int)
}

struct SongLyrics: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var lines: [LyricLine]
    var source: LyricsSource
    var language: String?
    var globalOffset: TimeInterval
    var updatedAt: Date
}

// SongAnalysis.swift
enum ChordQuality: String, Codable, Sendable {
    case major, minor, dom7, min7, maj7, min6, maj6
    case sus2, sus4, dim, dim7, halfDim, aug, power, none
}

struct ChordSegment: Codable, Identifiable, Sendable {
    let id: UUID
    var start: TimeInterval          // source-song seconds
    var end: TimeInterval
    var root: Int                    // pitch class 0…11
    var quality: ChordQuality
    var bass: Int?
    var confidence: Float
    var isUserEdited: Bool
    var barIndex: Int?
    var beatIndex: Int?
}

struct BeatGrid: Codable, Sendable {
    var beats: [TimeInterval]        // explicit list handles tempo drift
    var downbeatIndices: [Int]
    var beatsPerBar: Int
    var estimatedBPM: Double
    var isUserEdited: Bool
}

struct MusicalKey: Codable, Sendable {
    var tonic: Int
    var isMinor: Bool
    var confidence: Float
}

struct SongAnalysis: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var analysisVersion: Int
    var key: MusicalKey?
    var beats: BeatGrid?
    var chords: [ChordSegment]
    var sourceStemSet: [StemKind]
    var engine: String
    var generatedAt: Date
}
```

The render chain — transpose, simplify, spell in key, lay out — should be pure
free functions over `[ChordSegment]` and unit-tested directly.

---

## Risks

- **Playhead observation cost.** Two continuously updating views on top of a
  monolithic observable will be felt. Phase 0's `@Observable` migration is not
  optional polish.
- **Non-Western repertoire.** Twelve-template matching and Western-trained chord
  models will be confidently wrong on raga-based, modal, or drone-centred
  material. Detect low key-profile fit and say so.
- **Word-level lyric timing** only works well from Whisper DTW on a clean vocal
  stem, and singing degrades it. Treat it as a progressive enhancement.
- **Storage growth.** Whisper plus a chord model plus separation models push
  Application Support past 700 MB. Settings must be able to inspect and delete
  them.
- **Legal posture.** On-device transcription for personal practice in a
  sideloaded build differs from shipping lyric data. The LRCLIB toggle is the
  boundary that changes this analysis; keep it opt-in and documented.

## Definition of Done for every item

Inherited from `IMPROVEMENTS_PLAN.md`, plus:

- Analysis results are correctable, and corrections survive re-analysis.
- Confidence and provenance are visible wherever generated content is shown.
- Every feature degrades to a usable manual path when analysis is unavailable.
- Timestamps remain correct at every supported speed and transposition.
