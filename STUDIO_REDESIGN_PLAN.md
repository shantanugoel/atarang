# Studio Redesign and Song Analysis Plan

Covers the Studio layout redesign, the audio-layer work it depends on, synced
lyrics, and guitar chord detection with optional simplification.

This plan absorbs the analysis-assisted practice phase of the former
`PRACTICE_TOOLS_PLAN.md` (removed in `9858bbd`; recoverable with
`git show 9858bbd^:PRACTICE_TOOLS_PLAN.md`).

It also absorbs the **reliability, concurrency, and language-mode** work from
`IMPROVEMENTS_PLAN.md`, sequenced so the base is stable before new subsystems
are built on it. See "Relationship to `IMPROVEMENTS_PLAN.md`" below for exactly
which items are absorbed, which are dissolved by the redesign, and which are
deliberately deferred.

## Relationship to `IMPROVEMENTS_PLAN.md`

**Absorbed into this plan, in build order:**

| Item | Where | Note |
| --- | --- | --- |
| 13 Strict concurrency / Swift 6 | Phase 0 | Moved first: every new subsystem should be written under strict checking, not migrated afterwards |
| 12 Narrow SwiftUI observation | Phases 1, 4 | Delivered by the `@Observable` migration and the layout decomposition |
| 3 Recording writes fail-fast | Phase 2 | Active data-loss bug today |
| 2 Isolate recording exports | Phase 2 | Same subsystem |
| 5 Atomic installs and library commits | Phase 2 | Hard prerequisite for song-scoped analysis storage |
| 11 Library scanning off the main actor | Phase 3 | Grows more important as analysis adds files |
| 14 Refactor large views | Phase 4 | Intent kept; its boundary list is obsolete (see below) |
| 17 Progressive disclosure | Phase 4 | Delivered as tool chips |
| 18 Separation choices by outcome | Phase 4 | Cheap while the import screen is being rebuilt |
| 4 Capacity checks and storage policy | Phase 10 | Hard prerequisite for model downloads |
| 6 Library integrity and recovery | Phase 10 | Scope grows once lyrics/chords/beats files exist |
| 19 Settings surface | Phases 4, 6, 10 | Built for real: skeleton with the layout work, grown as later phases add preferences |

**Dissolved by the redesign — do not implement separately:**

- **Item 1, isolate separation operations.** The `AnalysisQueue` actor in
  Phase 3 owns separation as one job type, with single-owner, generation, and
  cancellation semantics built in. Bolting generation tokens onto
  `SeparationModel` first would be wasted work.
- **Item 14's recommended boundary list.** It names Mixer, Practice timeline,
  and Structured practice/metronome as components; those stop existing. The
  intent — feature views receiving only what they use — is kept in Phase 4
  against the new boundaries.

**Deliberately deferred** (still valid, tracked in `IMPROVEMENTS_PLAN.md`, not
scheduled here): items 7–10 (integration tests, CI gates, device matrix, yt-dlp
canary), 15 (MetricKit and signposts), 16 (interruption UI), 20 (local audio
import), 21 (formal accessibility QA). Accessibility remains a per-phase
acceptance criterion regardless.

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
- [x] **Chord-analysis design target: 4-stem.** Phase 8 tunes the analysis mix
      around bass and other. Guitar and piano stems improve results when the
      6-stem model was used, but nothing depends on them.
- [x] **Milestone A runs in strict order: 0 → 1 → 2 → 3 → 4.** No user-visible
      feature ships until the base is stable. Accepted deliberately.
- [x] **All per-song state moves to library metadata**, keyed by original ID,
      alongside analysis. Practice settings and stem levels leave `UserDefaults`
      in Phase 5. This ends practice state being lost on re-separation and gives
      it atomic writes, integrity checking, and one backup policy.
- [x] **A saved practice section stores its A–B range only.** Speed, key, mix,
      and target stay independent and live in the tool chips, so loading a
      section never silently changes what the user hears.
- [x] **No backward compatibility before 1.0.** The app has no users yet. No
      migrations, no legacy decoding paths, no deprecated keys. Existing
      pre-release compatibility scaffolding is deleted in Phase 0, and later
      phases change formats freely rather than versioning around them.
- [x] **Downloaded originals are reproducible cache.** Excluded from backup and
      safe to evict under storage pressure; they can be re-fetched from the
      source URL. Performances remain user data and are always preserved.
- [x] **Playback rate stays `0.5...1.0`.** Practising above original tempo is
      out of scope for now; the tempo ramp keeps 100% as its ceiling.
- [x] **The third tab becomes a real Settings tab**, with About as a section
      inside it. Reversed from an earlier call to rename it to About: once the
      preferences were enumerated there are eight genuine sections, several of
      which have nowhere else sensible to live. Settings owns app-level
      concerns — downloadable models, storage totals, privacy, defaults.
      Library keeps owning user *content*, so it does not grow a fourth
      non-content category.
- [x] **A missing practice target is reported, not silently swapped.** When a
      re-separation removes the targeted stem, fall back and tell the user once.
- [x] **Recording exports continue when another song is loaded**, keyed by
      recording ID and published to the Library item. See Phase 2.

## Guiding principles

Carried forward from the former practice-tools plan:

- Make common actions usable while the user is holding an instrument.
- Prefer a few prominent controls over a dense collection of audio tools.
- Preserve synchronization across all stems under every playback transform.
- Save practice state per song so the next session resumes naturally.
- Keep musical analysis optional; no manual practice feature may depend on
  beat, chord, or pitch detection.
- Explain stem limitations honestly. A guitar or piano practice target is only
  offered when that stem exists.
- Ensure VoiceOver, Dynamic Type, and minimum touch-target support in every
  phase.

Added by this plan:

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

## Phase 0 — Language, concurrency, and pre-release cleanup

**Goal:** Get the project onto strict concurrency and Swift 6, and delete the
compatibility scaffolding for a past that never shipped — **before** the new
subsystems are written.

This is first on purpose. Every later phase adds concurrent code; doing the
migration last would mean migrating several thousand new lines a second time.
The cleanup goes here too because deleting ~150 lines of hand-written decoders
makes the concurrency migration smaller, not larger.

### 1. Delete pre-release compatibility scaffolding

There are no users. Every tolerance below exists to read files written by
earlier development builds, and each one is a permanent tax on a format that
was never released.

- [ ] Replace the hand-written `init(from:)` in `SongPracticeSettings` (25
      `decodeIfPresent` calls) with synthesized `Codable`.
- [ ] Replace the hand-written `init(from:)` in `TrackMetadata` (6
      `decodeIfPresent` calls); make `separationModel` and `stems` required
      rather than defaulting to `.htdemucs`.
- [ ] Delete `PlaybackState`'s `Codable` conformance, custom decoder, and
      `schemaVersion` entirely — it is never persisted by the app, and its only
      exercise is two tests decoding a "legacy" format that never shipped.
      Delete those tests with it.
- [ ] Reset `SongPracticeSettings.currentSchemaVersion` to 1 for the first
      release.
- [ ] Remove `HistoryStore`'s ad-hoc metadata fallbacks (`metadata?.createdAt ??
      fallbackDate` and similar). Missing or damaged metadata becomes a Phase 10
      integrity concern with one explicit model, not a silent guess in three
      places.
- [ ] Remove the README claim that the Library "automatically discovers media
      created by older builds".
- [ ] Keep `separationCacheVersion` and the planned `analysisVersion` — those
      invalidate caches when a *model or algorithm* changes, which stays useful
      after 1.0. Keep `schemaVersion` on persisted types as a forward-looking
      field, but with no branching on it until there is something to branch on.

### 2. Strict concurrency and Swift 6

- [ ] Enable `SWIFT_STRICT_CONCURRENCY = complete` in Swift 5 mode and record
      the app-owned warning count as a baseline.
- [ ] Separate app-owned warnings from generated Core ML and package warnings.
- [ ] Remove concurrently mutated captured variables from `AVAudioConverter`
      input blocks.
- [ ] Encapsulate non-`Sendable` AVFoundation objects behind actor or queue
      ownership.
- [ ] Audit every `@unchecked Sendable` conformance — `StemPlayer`,
      `StemSeparator`, `ONNXModelSession`, `MDXSpectralTransform`,
      `AudioTapFileWriter`, `CoreMLWaveformSeparator` — and either document the
      synchronization invariant in code or remove the conformance.
- [ ] Isolate mutable state exposed by the YoutubeDL dependency.
- [ ] Drive app-owned strict-concurrency warnings to zero.
- [ ] Flip `SWIFT_VERSION` from 5.0 to 6.0 and resolve the resulting errors.
- [ ] Document any remaining generated-code warning with a containment strategy.

### Acceptance criteria

- [ ] The project builds under Swift 6 language mode with zero app-owned
      concurrency diagnostics.
- [ ] No `@unchecked Sendable` remains without a written invariant.
- [ ] No hand-written `Codable` conformance remains whose only purpose is
      tolerating a pre-release format.
- [ ] Playback, recording, separation, export, and Library behaviour are
      unchanged.

---

## Phase 1 — Audio foundation

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
      screen and headphone-remote play/pause/seek. This is the cheapest useful
      form of the parked "Bluetooth pedal, headphone remote" idea.
- [ ] Close the stem-synchronization verification left unfinished by the former
      practice plan: confirm all stems stay synchronized across seeking,
      pausing, route changes, interruptions, and repeated playback. This is an
      unverified assumption underneath everything else in this phase.
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

- [x] `supportedRateRange` stays `0.5...1.0`. Practising above original tempo is
      out of scope for now.

---

## Phase 2 — Recording and library data safety

**Goal:** Stop losing data. Two of these are active bugs; the third is a hard
prerequisite for the analysis storage introduced in Phase 5.

Absorbs `IMPROVEMENTS_PLAN.md` items 3, 2, and 5.

### 1. Recording writes fail-fast and transactional (item 3)

Today `micFile.write(from:)` and `mixWriter.write(_:)` failures are swallowed by
a bare `print()` inside the tap callbacks, and the take is still committed.

- [ ] Capture microphone and backing writer failures as state instead of
      printing and continuing.
- [ ] Stop the recording safely when either writer fails, with an actionable
      reason surfaced to the user.
- [ ] Write into a staging directory; commit only after both streams close and
      validate.
- [ ] Verify both files are readable with a plausible duration before writing
      metadata.
- [ ] Quarantine or remove failed staging directories.
- [ ] Consider a bounded writer queue so file I/O cannot block the audio
      callback.

### 2. Isolate recording exports (item 2)

Decided: **export continues when another song is loaded.** A take the user just
recorded should not lose its shareable file because they moved on, and once
export state is keyed by recording rather than by player it is also the simpler
implementation — `StemPlayer` stops owning `isExporting` and `shareURL` at all.

- [ ] Key exports by recording ID and generation token, not by current player
      context.
- [ ] Move `isExporting`, export errors, and `shareURL` off `StemPlayer` and
      onto the recording they belong to.
- [ ] Let an in-flight export run to completion across song changes and unload;
      publish completion to the Library item.
- [ ] Show export state in Studio only while the same recording is still loaded.
- [ ] Give export its own serial lane rather than queueing it behind Phase 3's
      heavy analysis jobs — a few-second export must not wait on a multi-minute
      chord analysis. Same job-identity discipline, different lane.
- [ ] Make completed exports discoverable from Library even when Studio has
      moved on.

### 3. Atomic installs and library commits (item 5)

- [ ] Download and generate into unique staging locations.
- [ ] Validate checksums, expected files, audio readability, and metadata before
      publishing.
- [ ] Commit by atomic replacement or final directory rename.
- [ ] Never remove a known-good yt-dlp or model asset before its replacement is
      ready.
- [ ] Revalidate installed optional models against a manifest rather than mere
      file existence.
- [ ] Sweep abandoned staging directories during startup maintenance.

### Acceptance criteria

- [ ] Simulated write failures end recording cleanly, and no failed recording
      appears as a valid Library performance.
- [ ] Loading another song during export never shows the previous song's export
      state or share URL.
- [ ] Forced termination at any commit boundary leaves either the previous valid
      asset or the new valid asset, never a partial one.
- [ ] A completed separation is either fully discoverable or fully absent.

---

## Phase 3 — Work isolation and library performance

**Goal:** One serialized owner for all long-running work, and a Library that
does not block the main thread. Both get harder to retrofit once analysis jobs
exist.

Absorbs `IMPROVEMENTS_PLAN.md` items 1 (dissolved into the queue) and 11.

### 1. AnalysisQueue

- [ ] Add an `AnalysisQueue` actor owning **separation, transcription, and
      chord/beat analysis** as job types. One job at a time, globally.
- [ ] Give every job a stable ID and generation token; make all state updates
      conditional on the job still being current.
- [ ] Make cancellation a distinct non-error terminal state that propagates to
      download, extraction, inference, and file generation.
- [ ] Prevent an older job's cleanup from clearing a newer job's progress,
      status, or task handle.
- [ ] Block every job while `StemPlayer.isRecording`.
- [ ] Run jobs at `.utility` QoS; make each idempotent, discarding partial
      output on failure.
- [ ] Report all jobs through one shared progress surface.
- [ ] Add structured `OSLog` signposts per job so chord and transcription work
      is debuggable. (A deliberately small slice of item 15.)

### 2. Library off the main actor (item 11)

- [ ] Move directory traversal, duration reads, and byte counting to a
      dedicated actor.
- [ ] Publish an immutable Library snapshot to the UI.
- [ ] Maintain a lightweight persistent index updated transactionally.
- [ ] Reconcile the index with disk incrementally rather than rescanning.
- [ ] Coalesce duplicate refresh notifications.
- [ ] Move existing-separation lookup out of `ContentView` and stop scanning
      while the user types.

### Acceptance criteria

- [ ] Starting job B immediately after cancelling job A never lets A alter B's
      progress, status, error, result, or task handle.
- [ ] Two long-running jobs never run concurrently, and none runs during a take.
- [ ] Repeated cancel/restart cycles leave no partial library entry.
- [ ] Library refresh does not block the main thread, and one data mutation
      produces at most one UI snapshot.

---

## Phase 4 — Studio layout

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
- [ ] Replace `StudioWorkspace` with `{lyrics, chords, sheet, mixer}`. No
      migration: pre-release, so change the enum and let the schema follow.

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

### 6. Import screen by outcome (item 18)

Cheap to fold in while this screen is being rebuilt anyway.

- [ ] Lead with outcome names — Balanced 4-stem, Detailed 6-stem, Vocals +
      Backing — and demote architecture names to secondary detail.
- [ ] Show speed class, stem list, device compatibility, download size, and
      installed status before confirmation.
- [ ] Badge a recommended default for the current device without preventing
      manual selection.
- [ ] Explain why a model is unavailable and what to choose instead.
- [ ] Separate `Separate Again` visually from the primary action so an expensive
      re-run is not a mis-tap.

### 7. Settings tab skeleton

The tab currently says "Settings" and contains version, author, and a GitHub
link. Give it the structure the later phases need, and move the preferences that
already exist but live in the wrong place.

- [ ] Build a sectioned Settings screen; keep **About** as a section within it.
- [ ] Move recording defaults — microphone and backing level — out of the Mix
      card. They are global defaults for new takes, not part of a song's mix.
      Live adjustment stays in the transport during recording.
- [ ] Add a **default separation model** preference and persist it.
      `SeparationModel.selectedModel` currently resets to `.htdemucs` on every
      launch, which is an existing annoyance rather than a design choice.
- [ ] Surface `THIRD_PARTY_LICENSES.md` in-app under About. The project bundles
      MIT-licensed work — Demucs weights, ONNX Runtime, ZIPFoundation,
      PythonKit, YoutubeDL-iOS, yt-dlp — and the notices are currently not
      reachable from the app at all.
- [ ] Leave placeholders out: sections appear when the phase that needs them
      lands, not before.

### 8. Adaptive layout

- [ ] Regular width: Stage left, tool inspector right, transport full width.
- [ ] Landscape iPhone: same split with the chip row folded into the transport.

### 9. Decomposition

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

## Phase 5 — Song-scoped analysis storage

**Goal:** One durable, song-scoped home for everything the app knows about a
song — practice state *and* analysis results. Job orchestration already exists
from Phase 3; this phase is only about storage.

### 1. Song-scoped storage

- [ ] Define song-scoped storage in `Application Support/Originals/<originalID>/`:
      `lyrics.json`, `chords.json`, `beats.json`, `practice.json`, written
      through `LibraryMetadata` and committed atomically per Phase 2.
- [ ] Resolve storage from `TrackMetadata.sourceOriginalID`, falling back to the
      track folder when the original has been deleted.
- [ ] Add an `analysisVersion` constant so improving an algorithm invalidates
      cached results, mirroring `separationCacheVersion`.
- [ ] Add analysis job types to the Phase 3 `AnalysisQueue`, gating model-backed
      jobs on `ModelMemoryBudget` as `htdemucs6s` already is.
- [ ] Extend the Phase 3 Library index and storage accounting to cover analysis
      artifacts.

### 2. Move practice state out of `UserDefaults`

All per-song state moves to library metadata keyed by **original** ID rather
than track ID. Pre-release, so this is a straight move: delete the old keys, no
migration, no deprecation window.

- [ ] Move `SongPracticeSettings` into `practice.json` beside the original and
      delete the `practiceSettings.v1.<trackID>` defaults key.
- [ ] Move stem levels into the same file and delete the `stemLevels.<trackID>`
      defaults key.
- [ ] Rewrite `PracticeSettingsStore` against `LibraryMetadata`; it should no
      longer reference `UserDefaults` at all.
- [ ] Keep `validate` as the sanity boundary for values, not as a compatibility
      shim.
- [ ] Apply one backup policy across the whole original folder.
- [ ] Leave global preferences — default mic and backing levels — in
      `UserDefaults`; they are not per-song.

### Acceptance criteria

- [ ] Re-separating a song with a different model preserves its lyrics, chords,
      beat grid, **and** its practice settings, loop, sections, and stem levels.
- [ ] A damaged or partially written analysis file never makes its song
      unopenable, and never loses practice state.
- [ ] When a re-separation removes the targeted stem, the app falls back and
      says so once, rather than silently practising a different part.
- [ ] Deleting an Original removes its analysis and practice artifacts, and
      storage totals reflect it.
- [ ] No per-song state remains in `UserDefaults`.

---

## Phase 6 — Synced lyrics, without any model

**Goal:** A complete, useful synced-lyrics feature with no ML and no new
accuracy risk.

### 1. Model and storage

- [ ] Add `Lyrics.swift`: `LyricWord`, `LyricLine`, `LyricsSource`, `SongLyrics`.
- [ ] Persist through the Phase 5 song-scoped storage.

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

## Phase 7 — Beat and downbeat grid

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

## Phase 8 — Chord detection, bundled tier

**Goal:** Useful chords with no download, honest about accuracy.

### 1. Feature extraction

- [ ] Build the analysis mix: `0.8·bass + other + guitar + piano`, excluding
      vocals and drums; record `sourceStemSet` with the result.
- [ ] Resample to 22.05 kHz mono.
- [ ] Compute a harmonic pitch-class profile with overtone suppression.
- [ ] Compute a separate bass chroma from the bass stem over ~40–250 Hz.
- [ ] Average chroma within beats from the Phase 7 grid.

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

## Phase 9 — Simplification, capo, and the Sheet view

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

## Phase 10 — Capacity, model management, and library integrity

**Goal:** Make the app safe to download large optional models into. This is the
gate in front of Milestone E, not optional polish — Whisper alone can be
~470 MB.

Absorbs `IMPROVEMENTS_PLAN.md` items 4, 6, and the required slice of 19.

### 1. Capacity and storage policy (item 4)

- [ ] Estimate required space before downloading, separating, recording,
      exporting, and analysing, including staging overhead.
- [ ] Block operations that cannot safely complete, using system capacity APIs
      and keeping a reserve rather than consuming all free space.
- [ ] State how much additional space is needed in the error copy.
- [ ] Exclude reproducible assets from backup: optional models, derived stems,
      **and downloaded originals**, which are re-fetchable from their source URL
      and are therefore cache. Performances are user data and are preserved.
- [ ] Allow originals to be evicted under storage pressure, with clear copy that
      re-separating will re-download.
- [ ] Show storage totals by Originals, Separations, Performances, Models,
      Analysis, and temporary data.

### 2. Library integrity and recovery (item 6)

- [ ] Distinguish valid, recoverable, incomplete, and corrupt library folders,
      now including `lyrics.json`, `chords.json`, and `beats.json`.
- [ ] Reconstruct safe metadata where IDs, filenames, duration, or dates can be
      derived reliably.
- [ ] Quarantine unrecoverable entries rather than silently skipping them.
- [ ] Never let a damaged analysis file make its song unopenable.
- [ ] Record structured diagnostics without exposing private media metadata.

### 3. Settings, completed (item 19)

The skeleton landed in Phase 4 and the lyrics preferences in Phase 6. This
phase adds everything that depends on downloadable assets.

- [ ] **Downloads & Models**: list every installed optional asset — four
      separation models, plus the Whisper and chord models from Milestone E —
      with size, install state, and a delete action.
- [ ] **Storage**: totals by Originals, Separations, Performances, Models,
      Analysis, and temporary data, with cleanup actions.
- [ ] Expose cached-originals eviction here, with copy explaining that
      re-separating will re-download.
- [ ] **Privacy & data**: what leaves the device and when, and the backup policy
      per category. Keep it consistent with the README.
- [ ] **Diagnostics**: export the structured library-integrity report from
      section 2 without exposing private media metadata.
- [ ] Keep per-item content deletion in Library; Settings owns aggregates and
      app-level assets, not individual songs or takes.

### Acceptance criteria

- [ ] Operations fail before starting when capacity is insufficient, with copy
      stating the shortfall.
- [ ] A partial model directory is never reported as installed.
- [ ] Corrupt fixtures produce explicit recoverable/unrecoverable results, and
      no item disappears without a diagnostic record.
- [ ] Every downloadable asset can be inspected and deleted from Settings.
- [ ] Storage totals match on-disk usage within an agreed tolerance.

---

## Phase 11 — Chord detection, optional model tier

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

## Phase 12 — Lyric transcription

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

### Milestone A — Stable base
Phases 0–3. Swift 6 with strict concurrency, an audio layer that can drive
accurate visuals and frequent seeking, recordings and library commits that
cannot silently corrupt, one serialized owner for long-running work, and a
Library that stays off the main thread.

No user-visible feature ships in this milestone. That is the cost of asking for
a reliable base first, and it is the right trade: every phase after this one
adds concurrent code and new file types on top of it.

### Milestone B — Studio
Phase 4. The layout redesign, delivered against a base that no longer fights it.

### Milestone C — Lyrics
Phases 5 and 6. Song-scoped analysis storage and a complete synced-lyrics
feature, with no model downloads.

### Milestone D — Chords
Phases 7–9. Beat grid, bundled chord detection, simplification, capo suggestion,
and the Sheet view — still with no model downloads.

### Milestone E — Models
Phases 10–12. Capacity and model management first, then optional models for
better chords and automatic lyric timing.

### Sequencing notes

- **Strict order through Milestone A is a decision, not a default.** Phases 2
  and 3 do not technically block Phase 4, but they run first anyway so that no
  feature work is built on a base that is still moving. Revisit only if
  something external forces visible progress sooner.
- **Phase 0 is not movable.** Migrating to Swift 6 after Phases 3–9 have added
  several thousand lines of concurrent code costs materially more than now.
- **Phase 10 is a gate, not a phase to skip.** Nothing in Milestone E should
  download until capacity checks and model management exist.

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
  monolithic observable will be felt. Phase 1's `@Observable` migration is not
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

## Carried forward but not scheduled

Recovered from the removed practice plan. These remain out of committed phases
until there is evidence of demand, but they are recorded here so they are not
lost with the file.

### Pitch feedback

The one substantial practice feature this plan does not cover. Unrelated to
lyrics and chords; would slot in after Milestone C.

- [ ] Prototype low-latency pitch contour capture for voice and monophonic
      instruments.
- [ ] Prefer a visual contour and reference comparison over a simplistic score.
- [ ] Clearly indicate uncertain or unvoiced regions.
- [ ] Validate against vibrato, slides, bends, octave errors, and background
      bleed.
- [ ] Keep raw performance recordings usable without analysis.

### Parked candidates

- [ ] Standalone tuner.
- [ ] Standalone metronome and technique routines.
- [ ] Timed practice blocks and practice logs.
- [ ] Bluetooth pedal, keyboard, or voice control. (Headphone remote is covered
      in Phase 1.)
- [ ] Continuous multi-loop session recording and best-take extraction.
- [ ] Shareable practice routines.

### Open decisions inherited from the practice plan

- [x] Does a saved practice section carry its own speed, key, and mix?
      **Resolved: A–B range only.** See "Decisions taken".
- [x] How much practice state belongs in `UserDefaults` versus library metadata?
      **Resolved: all of it moves to library metadata** in Phase 5.
- [x] What happens to a saved practice target that no longer exists after
      re-separation? **Resolved: fall back and tell the user once.** Silently
      practising a different stem is worse than a small interruption. Covered by
      a Phase 5 acceptance criterion.

---

## Definition of Done for every item

Inherited from `IMPROVEMENTS_PLAN.md`, plus:

- Analysis results are correctable, and corrections survive re-analysis.
- Confidence and provenance are visible wherever generated content is shown.
- Every feature degrades to a usable manual path when analysis is unavailable.
- Timestamps remain correct at every supported speed and transposition.

## Release checklist for every phase

Carried forward from the removed practice plan.

- [ ] Update user-facing help and accessibility labels.
- [ ] Verify compact and accessibility Dynamic Type layouts.
- [ ] Test VoiceOver focus order and control values.
- [ ] Test playback and recording with wired headphones, Bluetooth, and speaker.
- [ ] Test interruption, route-change, background, and screen-lock behavior.
- [ ] Test reopened tracks and older library metadata.
- [ ] Update `README.md` when the phase ships.
- [ ] Record known limitations and deferred work in this plan.
