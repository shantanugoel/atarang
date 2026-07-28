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

- [x] Replace the hand-written `init(from:)` in `SongPracticeSettings` (25
      `decodeIfPresent` calls) with synthesized `Codable`.
- [x] Replace the hand-written `init(from:)` in `TrackMetadata` (6
      `decodeIfPresent` calls); make `separationModel` and `stems` required
      rather than defaulting to `.htdemucs`.
- [x] Delete `PlaybackState`'s `Codable` conformance, custom decoder, and
      `schemaVersion` entirely — it is never persisted by the app, and its only
      exercise is two tests decoding a "legacy" format that never shipped.
      Delete those tests with it.
- [x] Reset `SongPracticeSettings.currentSchemaVersion` to 1 for the first
      release.
- [x] Remove `HistoryStore`'s ad-hoc metadata fallbacks (`metadata?.createdAt ??
      fallbackDate` and similar). Missing or damaged metadata becomes a Phase 10
      integrity concern with one explicit model, not a silent guess in three
      places.
- [x] Remove the README claim that the Library "automatically discovers media
      created by older builds".
- [x] Keep `separationCacheVersion` and the planned `analysisVersion` — those
      invalidate caches when a *model or algorithm* changes, which stays useful
      after 1.0. Keep `schemaVersion` on persisted types as a forward-looking
      field, but with no branching on it until there is something to branch on.

### 2. Strict concurrency and Swift 6

- [x] Enable `SWIFT_STRICT_CONCURRENCY = complete` in Swift 5 mode and record
      the app-owned warning count as a baseline.
- [x] Separate app-owned warnings from generated Core ML and package warnings.
- [x] Remove concurrently mutated captured variables from `AVAudioConverter`
      input blocks.
- [x] Encapsulate non-`Sendable` AVFoundation objects behind actor or queue
      ownership.
- [x] Audit every `@unchecked Sendable` conformance — `StemPlayer`,
      `StemSeparator`, `ONNXModelSession`, `MDXSpectralTransform`,
      `AudioTapFileWriter`, `CoreMLWaveformSeparator` — and either document the
      synchronization invariant in code or remove the conformance.
- [x] Isolate mutable state exposed by the YoutubeDL dependency.
- [x] Drive app-owned strict-concurrency warnings to zero.
- [x] Flip `SWIFT_VERSION` from 5.0 to 6.0 and resolve the resulting errors.
- [x] Document any remaining generated-code warning with a containment strategy.

### Acceptance criteria

- [x] The project builds under Swift 6 language mode with zero app-owned
      concurrency diagnostics.
- [x] No `@unchecked Sendable` remains without a written invariant.
- [x] No hand-written `Codable` conformance remains whose only purpose is
      tolerating a pre-release format.
- [~] Playback, recording, separation, export, and Library behaviour are
      unchanged. Confirmed on an iPhone 16 Pro Max: playback, looping, recording,
      export, take playback, Library browsing, route changes, interruption, lock,
      and background. **Separation is the one item never exercised on device**;
      it is the only thing keeping this from `[x]`, and nothing is blocked on it.
      Note that this criterion was previously signed off at `[~]` on unit tests
      and a simulator launch alone, and was false at the time — the device pass
      found that this phase's `SWIFT_VERSION` flip broke recording entirely. See
      the Outcome below.

### Outcome

**Baseline.** Turning on `SWIFT_STRICT_CONCURRENCY = complete` under Swift 5
produced 15 app-owned warnings across five files — the three separators'
`AVAudioConverter` input blocks (9), `BundledYTDLP` reading
`YoutubeDL.pythonModuleURL` (1), `ContentView.loopBoundaryEditor` (1), and
`RecordingMixPreviewPlayer.schedule` (1), plus three `@preconcurrency import`
suggestions. Four further warnings came from generated Core ML sources and none
from packages.

**Notable changes.**

- The three byte-identical `loadAndResample` implementations collapsed into
  `AudioResampler.stereoFloat32(fileURL:sampleRate:)`. Its
  `SingleBufferConverterInput` holds the buffer and the single-shot flag behind a
  lock, so the `@Sendable` input block no longer captures mutable locals.
- `StemPlayer`'s `@unchecked Sendable` was **removed**: the class is `@MainActor`,
  which already implies `Sendable`. `YTDLPSelection`'s was removed as well — every
  stored property is `Sendable`. The remaining six carry written invariants.
- `BundledYTDLP` became an actor owning both installation and every `yt_dlp`
  invocation, and is the only place that imports `YoutubeDL` as
  `@preconcurrency`.

**Generated Core ML warnings need no containment.** Xcode's model generator emits
`@preconcurrency import CoreML` when the target is in Swift 6 mode, so all four
warnings disappeared with the language-mode flip rather than needing suppression.

**This phase shipped a crash, and the deferred device pass is why.** Flipping to
Swift 6 made `StemPlayer.startRecording`'s microphone tap closure main-actor
isolated — it is written inside a `@MainActor` method and captured a bare,
non-`Sendable` `AVAudioFile`, and a capture that cannot cross actors forces that
inference. Under Swift 5 nothing enforced it; under Swift 6 the runtime asserts,
so the first buffer AVFAudio delivered on its render thread trapped with SIGTRAP.
Every attempt to record crashed, 100% of the time, and it sat on `main` for three
commits because the acceptance criterion above was signed off at `[~]` on unit
tests and a simulator launch. Fixed in `125292f` by holding the file behind
`AudioTapFileWriter` and marking both tap closures `@Sendable`. The lesson is
recorded in Phase 1's outcome: for the audio and recording layers, an
outstanding device pass is a blocker, not trailing paperwork.

**Known consequence.** `SongPracticeSettings`, `TrackMetadata`, and
`RecordingMetadata` now use synthesized decoding, which requires every key. Files
written by earlier development builds no longer decode: practice settings fall
back to defaults, and library folders whose metadata predates the current shape
are skipped by `HistoryStore` rather than reconstructed. This is the intended
pre-release behaviour, and Phase 10 replaces the skipping with explicit
recoverable/corrupt classification.

---

## Phase 1 — Audio foundation

**Goal:** Make the audio layer able to drive frame-accurate visuals and frequent
seeking, with the existing UI still in place so each change is verifiable
against known-good behaviour.

### Work

- [x] Add `StemPlayer.currentPosition() -> TimeInterval` computed on demand from
      `lastRenderTime`, falling back to `playbackState.position` when paused.
- [x] Subtract `AVAudioSession.outputLatency + ioBufferDuration` from the
      computed position so visuals match what is heard on Bluetooth routes.
- [x] Stop driving UI from the 10 Hz `Timer` alone; expose a display-rate path
      suitable for `CADisplayLink` or `TimelineView(.animation)`.
- [x] Fix the existing run-loop-mode defect: the position timer must continue
      firing during scroll tracking.
- [x] Apply the existing 2-second persistence throttle to every
      `persistPracticeSettings()` path; `seek` must not perform two
      `UserDefaults` JSON encodes per tap.
- [x] Pre-render a single metronome click buffer at load and schedule it per
      click in a rolling window, instead of synthesizing the whole remaining
      song's click track on the main actor inside `play()`.
- [x] Migrate `StemPlayer` to `@Observable` so SwiftUI tracks per-property
      instead of invalidating on every published change.
- [x] Replace the per-sample RMS loop in `meterLevel` with `vDSP_rmsqv`.
- [x] Guard the timing-stem path: if the first active stem schedules zero
      frames, fall back to another stem rather than silently losing position
      updates and loop completions.
- [x] Add `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` support for lock
      screen and headphone-remote play/pause/seek. This is the cheapest useful
      form of the parked "Bluetooth pedal, headphone remote" idea.
- [x] Close the stem-synchronization verification left unfinished by the former
      practice plan: confirm all stems stay synchronized across seeking,
      pausing, route changes, interruptions, and repeated playback. **Measured
      on an iPhone 16 Pro Max: 0.00 ms drift, 0.02 ms worst case**, sustained
      across ~30 engine restarts, seven loop wraps, a speaker-to-Bluetooth
      route change, lock/unlock, and recording.
- [x] Add `isIdleTimerDisabled` handling, scoped to full-screen practice modes.
- [x] Extend unit coverage: latency-compensated position, throttled persistence,
      click scheduling, timing-stem fallback.

### Acceptance criteria

- [x] The playhead continues updating while the user scrolls. Verified on
      device: no stall, worst gap 179 ms under scroll load.
- [~] Visual position matches audible position within 30 ms on wired output and
      within 50 ms on Bluetooth. **Bluetooth confirmed** — 173 ms of measured
      latency (163 output + 10 buffer) compensated, and reported as visually in
      sync. Speaker measures 36.7 ms, itself over the 30 ms budget
      uncompensated. Wired output remains untested: no wired headphones were
      available.
- [x] Ten consecutive seeks produce no audible hitch and no more than one
      settings write per second. Drag now costs one engine stop and one resume
      instead of ~30, and the click on release is gone. Audio is silent *during*
      a drag by design; audible scrubbing is Phase 4 work, if wanted at all.
- [x] Lock screen shows the current song; headphone play/pause works. Both
      confirmed on device, including correct play/pause iconography.
- [x] No regression in playback, looping, recording, export, or route handling.
      Verified on device: playback, looping, recording, export, playback of
      takes, route changes, interruption, lock, and background. Wired output and
      an incoming call were not exercised.

### Open decision

- [x] `supportedRateRange` stays `0.5...1.0`. Practising above original tempo is
      out of scope for now.

### Outcome

**New files.** `AudioTiming.swift` holds the pure pieces — `StemScheduling`,
`MetronomeClickPlan`, `WriteThrottle` — so the parts of playback that are easy
to get wrong are testable without an audio engine. `NowPlayingController.swift`
owns the lock screen and remote commands. `PlayheadView.swift` is the
display-rate wrapper.

**Notable changes.**

- The metronome no longer synthesizes a click track for the whole remaining
  song inside `play()`. Two ~18 ms buffers are rendered once at init and
  scheduled at absolute node times in a 3-second rolling window refilled by the
  position timer. Click level became a node gain, so changing it no longer
  restarts playback.
- `persistPracticeSettings()` is throttled on every path rather than only in
  `updatePosition`. Suppressed writes are not dropped: a flush task lands the
  last one, and `flushPracticeSettings()` is called on suspend, unload, take
  end, and scene deactivation. `unload()` now persists *before* rewinding,
  which also fixes closing a song resetting its resume point to zero.
- The timing stem is chosen per pass from the stems that actually schedule
  frames, instead of always `activeStems.first`.
- `@Observable` required replacing the two `didSet` recording-level properties
  with computed ones over `access`/`withMutation`, because the macro rewrites
  stored properties into accessors. All audio plumbing is `@ObservationIgnored`.

**Simulator verification.** Driven against a seeded synthetic 4-stem track
(`Application Support/Tracks/<id>/`), since separating a real song is not
feasible in the simulator. Confirmed: playback and the display-rate playhead;
the new smooth playhead marker tracking the slider; A–B looping wrapping
correctly rather than running to the end; the rewritten metronome surviving
~30 s of rolling-window refills across a loop wrap without stalling the graph;
practice state persisting through the throttle and restoring workspace, loop,
and playhead across a relaunch; the lock screen showing the song title.
Backgrounded playback continues while the app stays alive.

Two things the simulator could not settle were both later resolved on device
and were simulator artifacts: the lock-screen scrubber showed `--:--` there but
shows real times on hardware, and locking the simulator jetsams the app whereas
a device plays on unbroken. Note also that the timing-stem fallback cannot be
triggered through the UI — `duration` is the minimum across stems, so every
stem always has frames in a scheduled range. It is defensive code covered by
unit tests, not a fix for an observable bug.

**Idle timer scope.** There is no full-screen practice mode yet, so the hold is
scoped to the Studio tab with a song playing, recording, or counting in. Phase 6
extends it rather than replacing it.

**The device pass found three defects, two of them serious.**

1. **Recording crashed 100% of the time** with a Swift 6 isolation trap on
   AVFAudio's render thread. The microphone tap closure is written inside a
   `@MainActor` method and captured a bare `AVAudioFile`; a non-`Sendable`
   capture cannot cross actors, so Swift inferred the closure as main-actor
   isolated and the runtime enforced it. **This was Phase 0's**, not Phase 1's —
   the closure is byte-identical before Phase 1, and what changed was the
   `SWIFT_VERSION` flip to 6.0. It shipped on `main` for three commits because
   Phase 0's acceptance criterion was left at `[~]` for exactly the on-device
   recording pass that would have caught it. Fixed by holding the file behind
   `AudioTapFileWriter` and marking both tap closures `@Sendable`.
2. **Every slider value restarted the engine.** One drag produced ~30
   pause/reschedule/start cycles, audible as a click on release. Fixed with a
   scrubbing lifecycle wired through `onEditingChanged`.
3. **Headphone-remote resume did nothing on Bluetooth.** `pausePlayback` left
   the engine running, so iOS inferred we were still playing and kept sending
   `pause` — which a paused player correctly ignores. The lock screen showed a
   pause button while paused. Fixed by pausing the engine too.

**Process note.** Two of the three were only reachable on hardware, and the
worst was a total failure of a core feature sitting undetected behind a
deferred verification pass. Treat "device pass outstanding" as blocking for
the audio layer rather than as trailing paperwork.

**Recorded for Phase 4.** The A and B loop-boundary sliders derive A's range
from B's value (`0...loop.end - minimumDuration`), so adjusting B visibly jumps
the A knob; and B spans the whole song, making fine adjustment impractical
(~0.7 s per point on a four-minute track), which is why the ±0.1 s nudge
buttons exist. The transport rebuild replaces both.

**The reduced-rate convention was wrong, and it was wrong in the way this note
predicted.** Phase 2's device pass finally played a song at 0.5×, and the
playhead advanced at half its true speed: measured in the simulator afterwards
at 1.0 s of position per 4.0 s of wall clock, where 2.0 s was correct. The
player node's sample time is already in *song* seconds — the time-pitch unit
pulls the node at `rate`, so it renders half a second of file per second of
wall clock — and `calculatedPosition` scaled it by `rate` a second time. The
counter, the slider, the lock-screen position, the saved resume point, and the
displayed loop wrap were all wrong whenever the song was slowed down. Fixed by
scaling only the latency term, which is the one quantity genuinely measured in
real time. The old unit tests asserted the wrong value, which is why nothing
caught it; they now assert that node frames are song seconds at 1.0×, 0.75×,
and 0.5×.

**Speed and key changes no longer restart the engine.** Both were implemented as
pause, reschedule every stem, start — synchronously on the main actor. On device
that blocked long enough that the speed menu stayed on screen after the tap that
chose a speed, which is how the position bug was found. Because the playhead is
now derived from the node's own frame count, a mid-flight rate change needs no
re-anchoring: `AVAudioUnitTimePitch.rate` is set live and the music keeps
playing. `LiveRateChangeTests` renders the graph offline and holds that
assumption in place — after halving the rate, two seconds of output consume
exactly one second of file. The metronome keeps the restart path, because its
clicks are queued ahead on a wall-clock timeline built from the old rate and a
player node cannot unschedule a buffer. Its refill window also read the *stem*
clock as though it were wall time; it now reads the metronome node's own clock,
which is real time by construction.

**Still unverified after the device pass.**

- **Wired output**, for the 30 ms half of the sync criterion. No wired
  headphones were available.
- **Separation on device**, inherited from Phase 0, and an incoming call as a
  true interruption — the app-switch interruption was exercised, Siri only
  ducks.

---

## Phase 2 — Recording and library data safety

**Goal:** Stop losing data. Two of these are active bugs; the third is a hard
prerequisite for the analysis storage introduced in Phase 5.

Absorbs `IMPROVEMENTS_PLAN.md` items 3, 2, and 5.

### 1. Recording writes fail-fast and transactional (item 3)

Today `micFile.write(from:)` and `mixWriter.write(_:)` failures are swallowed by
a bare `print()` inside the tap callbacks, and the take is still committed.

- [x] Capture microphone and backing writer failures as state instead of
      printing and continuing.
- [x] Stop the recording safely when either writer fails, with an actionable
      reason surfaced to the user.
- [x] Write into a staging directory; commit only after both streams close and
      validate.
- [x] Verify both files are readable with a plausible duration before writing
      metadata.
- [x] Remove failed staging directories, and sweep any survivors at launch.
- [x] Add a bounded writer queue so file I/O cannot block the audio callback.
      Overflow fails the take rather than dropping audio.

### 2. Isolate recording exports (item 2)

Decided: **export continues when another song is loaded.** A take the user just
recorded should not lose its shareable file because they moved on, and once
export state is keyed by recording rather than by player it is also the simpler
implementation — `StemPlayer` stops owning `isExporting` and `shareURL` at all.

- [x] Key exports by recording ID and generation token, not by current player
      context.
- [x] Move `isExporting`, export errors, and `shareURL` off `StemPlayer` and
      onto the recording they belong to.
- [x] Let an in-flight export run to completion across song changes and unload;
      publish completion to the Library item.
- [x] Show export state in Studio only while the same recording is still loaded.
- [x] Give export its own serial lane rather than queueing it behind Phase 3's
      heavy analysis jobs — a few-second export must not wait on a multi-minute
      chord analysis. Same job-identity discipline, different lane.
- [x] Make completed exports discoverable from Library even when Studio has
      moved on.

### 3. Atomic installs and library commits (item 5)

- [x] Download and generate into unique staging locations.
- [x] Validate checksums, expected files, audio readability, and metadata before
      publishing.
- [x] Commit by atomic replacement or final directory rename.
- [x] Never remove a known-good yt-dlp or model asset before its replacement is
      ready.
- [x] Revalidate installed optional models against a manifest rather than mere
      file existence.
- [x] Sweep abandoned staging directories during startup maintenance.

### Acceptance criteria

- [x] Simulated write failures end recording cleanly, and no failed recording
      appears as a valid Library performance. Writer failure, backlog overflow,
      and unusable-audio validation are covered by unit tests; a storage failure
      at take setup was exercised in the simulator by making `Recordings`
      read-only, and produced an alert with no partial entry.
- [x] Loading another song during export never shows the previous song's export
      state or share URL. Studio reads export state through the loaded
      `recordedTake`'s ID, so there is no per-player export state left to show.
- [~] Forced termination at any commit boundary leaves either the previous valid
      asset or the new valid asset, never a partial one. True by construction —
      every publish is a rename or `replaceItemAt` — and the launch sweep was
      verified against a seeded abandoned staging directory. **A real
      kill-at-the-boundary test was not run**; it needs deterministic timing
      the simulator UI does not give.
- [x] A completed separation is either fully discoverable or fully absent. Stems
      are generated into hidden staging, every promised stem is checked for
      readability, `track.json` is written before the commit, and discovery
      skips hidden entries.

### Outcome

**New files.** `LibraryStaging.swift` is the one staging and commit rule for the
whole library. `AudioTapFileWriter.swift` lifts the writer out of `StemPlayer`
and gives it fail-fast semantics. `RecordingExportCenter.swift` owns exports and
the `SerialLane` they run on. `ModelInstallManifest.swift` defines what a
finished optional-model install looks like.

**One rule for every library write.** Staging directories are named
`.staging-<uuid>` inside the destination's own root. Every discovery pass in the
app already passed `.skipsHiddenFiles`, so a staged entry is unreachable by
construction rather than by a new check, and publishing is one `moveItem` or
`replaceItemAt` on the same volume. Recordings, originals, separations, new
Library mixes, optional models, and the yt-dlp install all go through it.
`sweepAbandonedStaging()` runs at launch, since nothing of ours can legitimately
be staging then.

**The writer no longer loses data in two different ways.**

- A failed write used to be a `print()` inside the tap callback, and the take was
  committed anyway. The first failure is now captured, reported once, and forces
  the take to end with an actionable message; the staging folder is discarded.
- File I/O left the render thread. Buffers are deep-copied and handed to a
  serial queue bounded at 64 buffers (~6 s). Overflow fails the take rather than
  quietly dropping audio, which is the only honest choice: a take with a silent
  hole in it looks fine and is worthless.

**Two bugs the new tests caught before the device ever saw them.** The first
draft of `finish()` set one `isClosed` flag that both stopped new writes and
made the queue skip pending ones, so the tail of every take was dropped — a
1.0 s fixture came back as 0.9 s. The same flag also swallowed the failure in a
take that ended promptly after a bad write, so `finish()` reported success on a
recording that had never been written at all. Both are fixed by separating
"closed to new buffers" from "drain what is queued"; `queue.sync` on the serial
queue does the draining.

**Exports belong to the recording now.** `StemPlayer` no longer has
`isExporting` or `shareURL`. `RecordingExportCenter` keys state by recording ID
with a generation token, runs work on a `SerialLane` — an actor is not enough,
because awaiting inside one lets the next caller in — and writes
`exportedFilename` into the recording's metadata on completion. Studio renders
the state of `player.recordedTake?.id` and nothing else, so a different song
simply has nothing to show. The Library's mix editor shares the lane so two
encoders never run at once.

**Model installs are what a manifest says they are.** `isInstalled` was
`fileExists`, which is true of a half-finished download and of a partially
extracted `.mlmodelc`. Installs now stage, verify SHA-256, load-test the
compiled Core ML model before publishing it, commit atomically, and only then
write `manifest.json`. Note the pre-release consequence: **models installed by
earlier builds have no manifest and will be downloaded again once.**

**Verified in the simulator against the Phase 1 synthetic track.** A loop take
recorded to `.staging-…`, validated, committed as `Recordings/<uuid>` with
metadata, exported to `Atarang Performance.m4a`, and appeared in the Library
with its share action. A seeded abandoned staging directory and a leftover
`.mix-*` file were both removed at the next launch. A read-only `Recordings`
folder made recording fail before it started — which is also how the raw
`NSFileManager` message ("You don't have permission to save the file
'.staging-…'") was found and replaced with `PlayerError.noRecordingStorage`.

### Device pass

Run on an iPhone 16 Pro Max. Everything this phase claims held up, and the pass
found three defects in **other** areas — which is the argument for doing it.

**Passed.** Several recordings committed with correct durations. Export
isolation: loading another song mid-export showed no stale state, and the take
completed into the Library. A route loss during a take stopped recording and
still saved a playable file. Force-quitting at the commit boundary left no new
performance and no staging directory. Optional models re-downloaded cleanly
after the manifest change.

**Deliberately skipped.** The storage-failure test (§1) — it needs a nearly-full
device or a debug injection, and is covered at the writer level by unit tests.

**Found elsewhere, all pre-existing:**

1. **The playhead ran at half speed at 0.5×.** Phase 1's known-unverified item,
   now measured, fixed, and recorded in that phase's outcome.
2. **The speed menu did not dismiss on device.** Same root cause area: the
   engine restart inside the menu's action blocked the main actor. Fixed by
   making rate and pitch live parameters.
3. **Separation could not be cancelled.** `Task.detached` swallowed the
   cancellation; see Phase 3.

**Still open.** `htdemucs6s` crashed during separation on device — likely the
`ModelMemoryBudget` gate being a launch-time check while ORT's CPU session peaks
higher during inference, but unconfirmed: the crash report has not been read
yet, because `devicectl` cannot mount the developer disk image on that phone.
Nothing in this phase touches the inference path.

---

## Phase 3 — Work isolation and library performance

**Goal:** One serialized owner for all long-running work, and a Library that
does not block the main thread. Both get harder to retrofit once analysis jobs
exist.

Absorbs `IMPROVEMENTS_PLAN.md` items 1 (dissolved into the queue) and 11.

### 1. AnalysisQueue

- [x] Add an `AnalysisQueue` actor owning **separation, transcription, and
      chord/beat analysis** as job types. One job at a time, globally.
- [x] Give every job a stable ID and generation token; make all state updates
      conditional on the job still being current.
- [x] Make cancellation a distinct non-error terminal state that propagates to
      download, extraction, inference, and file generation. **Inference was
      already done**, ahead of this phase: Phase 2's device pass found that
      Cancel did nothing at all, because all three separators ran their chunk
      loop inside a `Task.detached`, which inherits no cancellation — so their
      `Task.checkCancellation()` calls could never fire. `runCancellable` now
      forwards the cancel to the detached handle. The terminal state is now
      `AnalysisOutcome.cancelled`, and extraction and both downloads observe
      the cancel — see the outcome below.
- [x] Prevent an older job's cleanup from clearing a newer job's progress,
      status, or task handle.
- [x] Block every job while `StemPlayer.isRecording`.
- [x] Run jobs at `.utility` QoS; make each idempotent, discarding partial
      output on failure.
- [x] Report all jobs through one shared progress surface.
- [x] Add structured `OSLog` signposts per job so chord and transcription work
      is debuggable. (A deliberately small slice of item 15.)

### 2. Library off the main actor (item 11)

- [x] Move directory traversal, duration reads, and byte counting to a
      dedicated actor.
- [x] Publish an immutable Library snapshot to the UI.
- [x] Maintain a lightweight persistent index updated transactionally.
- [x] Reconcile the index with disk incrementally rather than rescanning.
- [x] Coalesce duplicate refresh notifications.
- [x] Move existing-separation lookup out of `ContentView` and stop scanning
      while the user types.

### Acceptance criteria

- [x] Starting job B immediately after cancelling job A never lets A alter B's
      progress, status, error, result, or task handle.
- [x] Two long-running jobs never run concurrently, and none runs during a take.
- [x] Repeated cancel/restart cycles leave no partial library entry.
- [x] Library refresh does not block the main thread, and one data mutation
      produces at most one UI snapshot.

### Outcome

**New files.** `AnalysisQueue.swift` holds three pieces: the `AnalysisQueue`
actor that serializes work, `AnalysisJobContext` — the only channel a running
job has for reporting itself — and `AnalysisProgressCenter`, the one
`@MainActor` surface the UI reads. `LibraryIndex.swift` holds `LibrarySnapshot`
and the `LibraryIndexer` actor.

**Notable changes.**

- `SeparationModel` lost `isWorking`, `progress`, `statusText`, and
  `estimatedRemainingText`. Those four properties *were* the cross-job bleed
  the acceptance criteria describe: one set of globals, so whichever job wrote
  last won. Progress is now an entry per job token, and a report whose token the
  center is no longer tracking is dropped rather than applied.
- The estimate moved with them, but keeps its old input. It is timed against the
  *inference* fraction, not overall progress — a separation spends its first
  fifth downloading and loading a model, and timing against that produced an
  estimate that finished early.
- Cancellation is `AnalysisOutcome.cancelled`, not a thrown `CancellationError`,
  so a stopped job no longer travels the same path as a failure. A `URLError`
  with code `.cancelled` maps to it too, because that is how URLSession says the
  same thing.
- Extraction became cancellable by *deleting* its `Task.detached`, not by
  wrapping it: `BundledYTDLP` has been an actor since Phase 0, so the
  interpreter already ran off the main actor and the detached task was only
  standing between the job and its cancellation. The audio download and the
  model download were already cancellation-aware through `URLSession`; what they
  lacked was cleanup, so the scratch folder now goes when the job does. The
  model install gained a cancellation check at each stage boundary — neither
  unzipping nor Core ML compilation can be interrupted part way, so stopping
  between them is as prompt as that path gets.
- The recording gate closes before the count-in rather than after the engine
  starts. A separation beginning during the three clicks before a take would be
  competing for the CPU by the first sung note. Every path out of
  `startRecording` that does not end up recording reopens it.
- `HistoryStore` publishes one `LibrarySnapshot` instead of three arrays, and
  listens for `atarangLibraryDidChange` itself instead of `ContentView` doing it
  — one place to coalesce, which matters because a single separation announces
  twice, once for the saved original and once for the finished stems. A burst of
  notifications now collapses into at most one extra pass.
- The index caches what is actually expensive: opening every audio file to
  measure duration, and walking every folder to add up bytes. Metadata JSON is
  re-read every pass, which keeps one source of truth for what an entry *is*.
  Measurements are keyed on the folder's modification date and child count, so
  recording one take remeasures one folder.
- Studio's existing-separation lookup reads the snapshot. It used to scan
  `Tracks/` on the main actor, on a 250 ms debounce, after every keystroke. A
  side effect worth having: the offer Studio makes and the item the Library lists
  are now the same fact rather than two independent scans that could disagree.
- Pull-to-refresh in the Library became `reload()`, which discards the cached
  measurements as well as the snapshot. The gesture exists for when the user
  believes what is on screen is wrong, so it should not trust the cache.

**Found by the tests.** The persistent index never survived a restart. Its
timestamps went through `LibraryMetadata`, whose ISO-8601 date strategy rounds
to the second, so a reloaded measurement never matched the modification date it
came from and the first refresh after every launch remeasured the whole library
— the exact cost the index exists to avoid. The same rounding would have missed
a folder changed within the same second as its measurement. Timestamps are now
stored as intervals.

**Not verified on device.** This phase is all timing and file access, both of
which behave differently on real storage under real thermal conditions. The
simulator pass covered the Library reading through the actor with measured
durations and byte counts, the snapshot-driven lookup resolving as a URL is
typed, and opening a saved separation from it.

---

## Phase 4 — Studio layout

**Goal:** Replace the Mix/Practice split with the transport + Stage + chips
structure, creating the space lyrics and chords need. No new analysis.

### 1. Persistent transport

- [x] Build a two-row transport pinned via `safeAreaInset`.
- [x] Row 1: scrubbable timeline with playhead, A/B markers, shaded loop region,
      and saved-section ticks.
- [x] Render a static waveform overview once at load from the summed stems;
      cache it beside the track.
- [x] Row 2: back-5, play/pause, record, loop toggle, speed chip, key chip.
- [x] Delete the two in-scroll position sliders; the transport is the single
      source of truth for seeking.

### 2. Stage container

- [x] Add a Stage area with a segmented and swipeable selector.
- [x] Move the existing stem mixer into the **Mixer** stage unchanged.
- [x] Add placeholder **Lyrics** and **Chords** stages with their empty states.
      Sheet ships with one too, so the selector never changes shape later.
- [x] Replace `StudioWorkspace` with `{lyrics, chords, sheet, mixer}`. No
      migration: pre-release, so change the enum and let the schema follow.

### 3. Practice tools as chips

- [x] Build a horizontally scrolling chip row that displays each tool's current
      value.
- [x] Chips: Loop, Speed, Key, Target, Click, Reps, Sections, Count-in.
- [x] Each chip opens a medium-detent sheet containing only that tool.
- [x] Remove `practiceWorkspace` and its always-expanded sections.

### 4. Recording as a mode

- [x] Consolidate mic level, backing level, live meter, and echo-cancellation
      status into the transport during recording. The two levels are shown, not
      adjustable — see the outcome.
- [x] Replace scattered disabled states with one clear mode explanation.
- [x] Surface loop-take comparison (Reference / Latest Take) in the same place.

### 5. Chrome and navigation

- [x] Restore the system navigation bar; delete the hand-drawn `mixerHeader`.
- [x] Move New Song, Share, Separate Again, Reset Practice Settings, and future
      analysis actions into a toolbar menu.
- [x] Add haptics on A/B set, loop wraparound, count-in ticks, and repetition
      target reached.
- [x] Auto-dismiss the notice banner.

### 6. Import screen by outcome (item 18)

Cheap to fold in while this screen is being rebuilt anyway.

- [x] Lead with outcome names — Balanced 4-stem, Detailed 6-stem, Vocals +
      Backing — and demote architecture names to secondary detail.
- [x] Show speed class, stem list, device compatibility, download size, and
      installed status before confirmation.
- [x] Badge a recommended default for the current device without preventing
      manual selection.
- [x] Explain why a model is unavailable and what to choose instead.
- [x] Separate `Separate Again` visually from the primary action so an expensive
      re-run is not a mis-tap.

### 7. Settings tab skeleton

The tab currently says "Settings" and contains version, author, and a GitHub
link. Give it the structure the later phases need, and move the preferences that
already exist but live in the wrong place.

- [x] Build a sectioned Settings screen; keep **About** as a section within it.
- [x] Move recording defaults — microphone and backing level — out of the Mix
      card. They are global defaults for new takes, not part of a song's mix.
      ~~Live adjustment stays in the transport during recording.~~ Reversed: the
      levels are metadata captured once per take, so there is nothing live to
      adjust. See the outcome.
- [x] Add a **default separation model** preference and persist it.
      `SeparationModel.selectedModel` currently resets to `.htdemucs` on every
      launch, which is an existing annoyance rather than a design choice.
- [x] Surface `THIRD_PARTY_LICENSES.md` in-app under About. The project bundles
      MIT-licensed work — Demucs weights, ONNX Runtime, ZIPFoundation,
      PythonKit, YoutubeDL-iOS, yt-dlp — and the notices are currently not
      reachable from the app at all.
- [x] Leave placeholders out: sections appear when the phase that needs them
      lands, not before.

### 8. Adaptive layout

- [x] Regular width: Stage left, tool inspector right, transport full width.
- [x] Landscape iPhone: same split with the chip row folded into the transport.

### 9. Decomposition

- [x] Split `ContentView.swift` into `TransportBar`, `StageContainer`,
      `ToolChipRow`, `ImportView`, and `RecordingMode`.

### Acceptance criteria

- [x] A first-time user can set an A–B loop, slow it down, and repeat it without
      opening more than one sheet. Measured in the simulator: A–B is two taps of
      the transport's A–B button (no sheet), speed is a two-tap menu (no sheet),
      repetitions is the one sheet.
- [x] Every capability previously in Mix or Practice is reachable within one
      additional interaction. Everything in the old Practice stack is one chip
      tap away; the Mix card's stem rows are the Mixer stage; its recording
      levels moved to Settings and its position slider became the transport.
- [x] The playhead and transport are visible at all times when a song is loaded.
      Nothing about the Studio screen scrolls except inside a Stage.
- [~] Dynamic Type at accessibility sizes, VoiceOver reading order, and 44pt
      targets are preserved throughout. **Dynamic Type verified** at
      accessibility-extra-large — it found two defects, both fixed. Touch targets
      are 44pt by construction. **VoiceOver reading order was not tested**; it
      needs a device pass and is the reason this is not `[x]`.
- [~] Existing per-song persisted state loads correctly after the schema bump.
      New state round-trips, and the app opens songs written by earlier builds.
      But `workspace` became `stage` under synthesized `Codable`, so settings
      written before this phase do **not** decode and the song opens with
      defaults. That is the pre-release behaviour the plan asked for; it is
      recorded as `[~]` rather than `[x]` because "loads correctly" is not what
      happens to those files.

### Outcome

**New files.** `TransportBar.swift` (transport, timeline, speed and key menus,
waveform shape), `StageContainer.swift` (stage selector, Mixer stage,
placeholders, `StemRow`), `ToolChipRow.swift` (the eight chips and their sheet
contents), `ImportView.swift`, `RecordingMode.swift`, `SettingsView.swift`,
`WaveformOverview.swift`, `Haptics.swift`, `StudioFormatting.swift`.
`ContentView.swift` went from 1,895 lines to about 700 and is now a coordinator:
objects, navigation, and the wiring between them. `AboutView.swift` is gone.

**The A–B button is why setting a loop needs no sheet.** Row 2's loop control is
the one practice hardware has used for decades: tap to drop A, tap again to drop
B and start looping, tap again to switch looping off, long-press for Set A / Set
B / Clear. The timeline's A and B handles then do the coarse adjustment by drag,
and the Loop sheet keeps only the ±0.1 s nudges. That retires both problems
Phase 1 recorded about the old boundary sliders — A's range deriving from B, and
B spanning the whole song at ~0.7 s per point — without needing a better slider.

**The waveform overview is RMS, not peaks, and stems combine as energy.** A peak
overview of a drum stem is a solid block, which says nothing about song
structure. Buckets hold mean square per stem and combine as the square root of
the sum of squares — what uncorrelated sources actually do — then normalise.
480 buckets, measured off the main actor at `.utility`, cached as `waveform.json`
beside the stems so it dies with them rather than outliving a re-separation.

**Recording levels are shown, not adjusted.** The plan expected live adjustment
in the transport. There is nothing to adjust: the microphone and backing levels
are one scalar each, snapshotted at take start and written into the recording's
metadata, and the raw streams are balanced later by the Library's mix editor.
A slider that moved during a take would either do nothing or silently rewrite
what the take claims it was recorded at. The strip shows both values with the
meter and the echo-cancellation state, and says where to change the balance.

**One mode explanation replaced a dozen disabled controls.** The chip row is
disabled and dimmed as a unit while recording, with the red strip above it
saying what is locked and why — instead of eight tools that each quietly stopped
responding.

**Landscape needed the chips in the control row, not under it.** The first
landscape build gave the Stage and the inspector about 90 points between them,
because the transport had grown a fourth row. Folding the chips into the same
`HStack` as the transport buttons, and shortening the timeline track from 56 to
36 points when the vertical size class is compact, brings the split back to
roughly half the screen.

**Two defects came out of the accessibility-size pass**, both invisible at
default sizes: a fixed 46×34 icon capsule squashed the play triangle into a
wedge once the glyph scaled, and the timeline's time readout — positioned as an
overlay with a hardcoded 18-point offset — grew tall enough to overlap the
waveform. The capsule now grows with its glyph, and the readout is a sibling in
a `VStack` rather than an offset overlay.

**`ViewThatFits` decides how many rows the transport needs.** Six controls fit
on one row at normal text sizes and do not at accessibility sizes, and a
truncated "10 0%" speed readout is worse than a second line.

**The last-used separation is the default now.** `SeparationModel.selectedModel`
persists to `UserDefaults` and is validated against the device on launch, so a
saved 6-stem preference on a device that cannot run it falls back rather than
presenting an unusable default. Note the consequence: separating from the
Library with a different model also changes the default, because it is genuinely
the same preference.

**Simulator verification.** Driven against a seeded synthetic 4-stem track with
deliberate loud and quiet sections, on an iPhone 17 Pro. Confirmed: the waveform
overview showing the seeded structure; A–B set from the transport in two taps
with handles, shading, and readout; looping wrapping and the repetition target
stopping playback at B; chips reporting live values ("1/2", then "2/2"); the
Reps sheet at medium detent; swiping the Stage moving the segmented control; the
recording strip with meter, levels, and one explanation while the chip row is
disabled as a whole; a loop take stopping at B by itself and the Compare strip
appearing; the toolbar menu carrying New Song, Share Performance, Separate
Again, and Reset Practice Settings; Settings with recording defaults, the
default separation, About, and the bundled third-party notices; and the
landscape split with the chips folded into the transport.

**Not verified on device.** Haptics have never fired on hardware — the simulator
has no Taptic Engine — so A/B set, loop wrap, count-in ticks, and target reached
are unexercised. VoiceOver reading order is untested. Neither is in the audio
layer that Phase 1 declared device-blocking, but both are the obvious first
items for the next device pass.

**Deliberately not built.** The Stage's three empty states are empty on purpose;
Milestones C and D fill them. Settings has three sections rather than eight —
downloads, storage, privacy, and diagnostics arrive with Phase 10, and a
placeholder that says "coming soon" is worse than no section.

---

## Phase 5 — Song-scoped analysis storage

**Goal:** One durable, song-scoped home for everything the app knows about a
song — practice state *and* analysis results. Job orchestration already exists
from Phase 3; this phase is only about storage.

### 1. Song-scoped storage

- [x] Define song-scoped storage in `Application Support/Originals/<originalID>/`:
      `lyrics.json`, `chords.json`, `beats.json`, `practice.json`, written
      through `LibraryMetadata` and committed atomically per Phase 2.
- [x] Resolve storage from `TrackMetadata.sourceOriginalID`, falling back to the
      track folder when the original has been deleted.
- [x] Add an `analysisVersion` constant so improving an algorithm invalidates
      cached results, mirroring `separationCacheVersion`.
- [x] Add analysis job types to the Phase 3 `AnalysisQueue`, gating model-backed
      jobs on `ModelMemoryBudget` as `htdemucs6s` already is. The gate is a
      per-submission byte requirement checked when the job reaches the front of
      the queue, not a per-kind constant — see the outcome.
- [x] Extend the Phase 3 Library index and storage accounting to cover analysis
      artifacts.

### 2. Move practice state out of `UserDefaults`

All per-song state moves to library metadata keyed by **original** ID rather
than track ID. Pre-release, so this is a straight move: delete the old keys, no
migration, no deprecation window.

- [x] Move `SongPracticeSettings` into `practice.json` beside the original and
      delete the `practiceSettings.v1.<trackID>` defaults key.
- [x] Move stem levels into the same file and delete the `stemLevels.<trackID>`
      defaults key.
- [x] Rewrite `PracticeSettingsStore` against `LibraryMetadata`; it should no
      longer reference `UserDefaults` at all.
- [x] Keep `validate` as the sanity boundary for values, not as a compatibility
      shim.
- [x] Apply one backup policy across the whole original folder. One rule, two
      answers, because the folder now holds two kinds of thing — see the outcome.
- [x] Leave global preferences — default mic and backing levels — in
      `UserDefaults`; they are not per-song.

### Acceptance criteria

- [~] Re-separating a song with a different model preserves its lyrics, chords,
      beat grid, **and** its practice settings, loop, sections, and stem levels.
      Verified in the simulator for practice settings, loop, and stem levels
      across a 4-stem → 2-stem re-separation. Lyrics, chords, and beats have no
      producer yet; the storage they will use is covered by unit tests against a
      stub artifact, which is as far as this phase can take it.
- [x] A damaged or partially written analysis file never makes its song
      unopenable, and never loses practice state. Reads are non-throwing by
      construction and the two files are independent; both are unit-tested with
      deliberately truncated JSON.
- [x] When a re-separation removes the targeted stem, the app falls back and
      says so once, rather than silently practising a different part. Confirmed
      in the simulator: opening a 2-stem separation of a song whose target was
      Drums shows the caution banner and falls back to Vocals.
- [x] Deleting an Original removes its analysis and practice artifacts, and
      storage totals reflect it. Confirmed in the simulator: the folder and its
      `practice.json` are gone and the Originals total drops to zero.
- [x] No per-song state remains in `UserDefaults`. Neither key is written any
      more, and a launch sweep removes the ones earlier builds wrote. The sweep
      is unit-tested; the simulator check was inconclusive because `cfprefsd`
      caches the preference file behind the app.

### Outcome

**New files.** `SongStorage.swift` holds the whole phase: the `SongStorage`
value that resolves and addresses a song's folder, the `AnalysisArtifact`
protocol that gives every future analysis result its version and filename, and
the backup rule. `TemporaryLibrary.swift` and `SongStorageTests.swift` are its
test support and coverage.

**Practice state is addressed by song now, not by separation.** `LocalTrack`
gained `folderURL` so a song can name its fallback, and
`SongStorage.resolve(originalID:trackFolder:)` prefers `Originals/<id>/` and
falls back to the separation's own folder when the original has been deleted.
The fallback dies with that separation, which is the honest outcome: there is no
longer a song for it to outlive. `PracticeSettingsStore` no longer mentions
`UserDefaults`; it reads and writes `practice.json` through `LibraryMetadata`,
whose encode-and-replace is already atomic.

**Stem levels stopped being their own store.** They were a separate
`UserDefaults` dictionary written synchronously on every fader move. They are
now `stemLevels` inside `SongPracticeSettings`, so they share one file, one
throttle, and one atomic write with the rest of the practice state — and survive
re-separation with it. `validate` keeps levels for stems this separation does
not have, so separating 4-stem and then 6-stem again finds the guitar fader
where it was left; only keys naming no stem at all are dropped.

**A missing practice target is reported, and the report is not on a timer.**
`validate` returns a `PracticeSettingsValidation` instead of silently swapping
the target, and `ContentView.load` turns it into a notice — at the single load
site, so the Library, a re-separation, and a fresh separation all report it
rather than only the two paths that also show a confirmation. That made the
banner's one style wrong: a green tick on "your practice target is gone" is the
interface agreeing with itself. `StudioNotice` now has a confirmation kind and a
caution kind, and only confirmations auto-dismiss. The caution stays until it is
dismissed or another song is opened, which is also why it is visible at all —
the first three simulator attempts appeared to show nothing, and the notice had
in fact been raised, shown, and cleared by the 5-second timer before the
screenshot came back.

**The memory gate is per submission, not per job kind.** The plan asked for
model-backed jobs to be gated "as `htdemucs6s` already is". A per-kind constant
would have meant inventing numbers for transcription and chord analysis before
either exists, so `AnalysisQueue.submit` takes an optional
`requiredMemoryBytes` and the caller — which knows what model it is about to
run — supplies it. It is checked when the job reaches the front of the queue
rather than at submission, because a job that waited ten minutes behind a
separation is starting on a different device than the one it was submitted to.
Separation now passes `SeparationModelKind.minimumAvailableMemoryBytes`, so the
6-stem gate exists at run time as well as at selection time. `beatAnalysis`
joined the job kinds for Phase 7.

**`os_proc_available_memory()` returns zero in the simulator**, which is why the
queue takes its memory reading as an injectable closure. The real one is
untestable there — and it also means `htdemucs6s` reports as unavailable in
every simulator, which is pre-existing behaviour this phase leaves alone.

**One backup policy, two answers, and the bullet as written no longer works.**
The plan's decision that downloaded originals are reproducible cache predates
practice state moving into the same folder. Excluding the folder as a whole would
now exclude the user's own work from their backups. The rule is therefore stated
once, in `SongStorage.applyBackupPolicy`, and it says: the downloaded audio is
excluded because it can be fetched again from its source URL; everything else in
the folder — settings the user tuned, loops they set, corrections they will make
to an analysis — is backed up, and the folder itself is never excluded. Applied
while staging, so a committed original is never briefly in the wrong state.

**Storage accounting names the song's own data.** `LibraryIndexer` measures the
practice and analysis files separately from the folder total and publishes
`songDataByteCount` on originals and tracks, with totals on `LibrarySnapshot`.
No new UI: the storage screen is Phase 10's, and the number is there for it.

**Note for Phase 10.** The index gained a field, so index files written by
earlier builds no longer decode — synthesized `Codable` requires every key. The
cost is one slow refresh, which is exactly what the index is allowed to cost.

**Simulator verification.** Driven against a seeded original and two seeded
separations of it (4-stem and 2-stem) on an iPhone 17 Pro. Confirmed:
`practice.json` written beside the original with the loop, target, and stem
levels; those settings intact after opening a separation made with a different
model; the caution banner naming the missing Drums stem and the fallback to
Vocals; deleting the Original removing its `practice.json` with it and the
Originals total returning to zero.

**Not verified on device.** Nothing in this phase touches the audio layer that
Phase 1 declared device-blocking. The device pass still owes Phase 4's haptics
and VoiceOver reading order.

---

## Phase 6 — Synced lyrics, without any model

**Goal:** A complete, useful synced-lyrics feature with no ML and no new
accuracy risk.

### 1. Model and storage

- [x] Add `Lyrics.swift`: `LyricWord`, `LyricLine`, `LyricsSource`, `SongLyrics`.
- [x] Persist through the Phase 5 song-scoped storage. Read *without* the
      version gate the other artifacts use — see the outcome.

### 2. Reading view

- [x] Current line large and centred; two lines above and below dimmed.
- [x] Auto-scroll follows the playhead; user scroll suspends it and shows a
      "Back to playhead" pill.
- [x] Word-level fill sweep when word timings are present. Word granularity, not
      a geometric sweep — see the outcome.
- [x] Tap a line to seek to it.
- [x] Long-press a line to loop it; drag across lines to set A–B. One gesture,
      not two.
- [x] Vocal-entry countdown after instrumental gaps longer than four seconds.
- [x] Render section labels inline and offer to populate Saved Sections from
      them.
- [x] Publish only `currentLineIndex` so a line change redraws two rows, not the
      tree. `LyricsPlayhead` is a separate object from the store for exactly
      this.

### 3. Sing-along mode

- [x] Full-screen presentation: large type, chords hidden, reduced transport,
      idle timer disabled, landscape supported.
- [x] Small unobtrusive mic meter while recording.

### 4. Input and editing

- [x] Paste plain lyrics.
- [x] Import and export `.lrc`, including `[mm:ss.xx]` line tags,
      `<mm:ss.xx>` word tags, and `[offset:]`.
- [x] Accept `.lrc` from the document picker and the share sheet.
- [x] Tap-to-timestamp mode: play, tap `Set` per line, advance automatically.
- [x] Per-line nudge ±0.1 s and a global offset slider ±2 s.
- [x] Mark every edited line `isUserEdited`; never overwrite on re-analysis.

### 5. YouTube captions

- [x] Extend the existing `yt_dlp(argv:)` call with `--write-subs
      --write-auto-subs --sub-langs --sub-format vtt --skip-download`.
- [x] Parse WebVTT cues into `LyricLine`s, marked `.youtubeCaptions`, low
      confidence, fully editable.
- [x] Offer them with a preview rather than applying them silently.

### 6. LRCLIB lookup (opt-in)

- [x] Add a Settings toggle, off by default, with a clear statement of what is
      sent.
- [x] Look up by title, artist, and duration; present candidates for
      confirmation.
- [x] Update the README privacy section when this ships.

### Acceptance criteria

- [~] Line-level sync is accurate to within ±150 ms after a single
      tap-to-timestamp pass. The stamp is taken from `currentPosition()`, which
      is the latency-compensated render clock, so the app contributes no error
      beyond one frame. **The number itself is unmeasured**: it is dominated by
      human reaction time, and quantifying that needs a device, a real song, and
      a reference the simulator cannot provide.
- [x] A song with no network access can be fully lyric-synced by hand. Verified
      in the simulator end to end: pasted seven lines, timed all seven by
      tapping, and the result read back correctly after a relaunch.
- [~] Auto-scroll remains smooth at 0.5× speed and at ±12 semitones. Correct by
      construction — every timestamp is in source-song seconds and the playhead
      is derived from the node's frame count, which Phase 1 fixed for exactly
      this. Confirmed smooth at 1.0×; the reduced-rate and transposed cases were
      not driven.
- [x] Transcribed or imported lyrics are visibly labelled until edited. The
      badge names the source while any line is still unedited and is replaced by
      the timed-line count once they all are; unit-tested line by line.
- [x] Lyric-range looping produces the same result as setting A–B manually. True
      by construction: the reader calls `setLoopBoundaryA(at:)`,
      `setLoopBoundaryB(at:)`, `setLoopEnabled(true)` — the transport's own
      calls. Confirmed in the simulator: dragging across three lines produced
      A 0:39 / B 1:00 with the handles, shading, and chip the button produces.

### Outcome

**New files.** `Lyrics.swift` is the model and every question that can be asked
of it — which line is current, which word, how long the gap is, what range a run
of lines covers. `LyricsFormats.swift` reads and writes `.lrc`, plain text, and
WebVTT. `LyricsStore.swift` owns a song's words while it is open, plus
`LyricsPlayhead`. `LyricsStage.swift` is the reader, `LyricsEditor.swift` the
five sheets, `SingAlongView.swift` the full-screen mode, and
`LyricsLookup.swift` the two places words can come from without typing.

**Lyrics are the one artifact that is half the user's own work, so they are not
version-gated.** `SongLyrics` conforms to `AnalysisArtifact` for its filename
and version, but the store reads it with a plain `read` rather than
`readAnalysis`. Discarding a stale chord grid is right — it is output we would
now compute differently. Discarding lyrics on a version bump would delete words
the user typed and times they tapped, which no algorithm change can make wrong.

**Three of the four format problems were about hostile input, not syntax.**
`[Chorus]` is not a timestamp and not a `key:value` tag, so the LRC scanner
stops consuming brackets and hands the rest to the text — which is what makes a
section marker fall out of the parser rather than needing a second pass.
`[offset:]` is defined the opposite way round from the app's slider, positive
meaning *earlier*, so the sign is flipped on the way in and back on the way out.
And YouTube's automatic captions roll: each cue repeats the tail of the one
before it so the words appear to scroll, which printed verbatim gives a page
where every line appears two or three times. A cue that merely extends its
predecessor now contributes only what it adds.

**The word sweep is per-word colouring, not a geometric fill.** A mask sweeping
across the line would have to know where every line break landed, and a lyric
line wraps. Word granularity is what the timings carry anyway, so the current
line is one `Text` built from an `AttributedString` — sung words full strength,
the current word tinted, the rest secondary — rebuilt at display rate by a
`TimelineView` inside the current row only.

**Hold-to-loop and drag-to-loop are one gesture.** They are the same intent at
two sizes: a long press selects the line under the finger, and keeping hold and
dragging extends the selection. Sequencing it behind a long press is what keeps
it from fighting the scroll view. Row geometry is measured through a preference
key **only while a selection is live** — measuring all the time would mean every
scrolled frame writing a new dictionary into state and re-evaluating the page.

**Two integers, one object.** The store holds hundreds of lines that change only
when the user edits; `LyricsPlayhead` holds the line index and the countdown,
which change while the song plays. Splitting them is what stops a line change
from invalidating the views that read the lyrics themselves. It is fed by a
`Color.clear` leaf watching `player.position` — the same trick `PlayheadView`
uses, and for the same reason: reading that property anywhere larger costs ten
full re-evaluations a second.

**The simulator pass found one defect, and it was in the gesture.** A tap that
lingered past 0.35 s recognised the long press, then lost to the tap gesture on
release — and because the selection lived in `@State`, `onEnded` never ran and
the line stayed highlighted with no gesture behind it. It is `@GestureState` now,
which SwiftUI resets on cancellation. The haptic moved out of the gesture's
`updating` body with it: that body is not main-actor isolated, so it is driven
from an `onChange` of the state it produces instead.

**Simulator verification.** Driven against a seeded synthetic 4-stem track and a
matching Original on an iPhone 17 Pro. Confirmed: the empty state offering
captions only because the song has a YouTube source; pasting seven lines with
two `[…]` markers, rendered inline as section headers; timing all seven by
tapping `Set` against playing audio, with the cursor advancing and Undo walking
back; the editor showing each time, its ±0.1 s nudges, and the edited-by-you
mark; the reader following the playhead with the current line large and the fade
ramp either side; tapping a line seeking to it; a long press dragged across three
lines setting A 0:39 / B 1:00 and turning looping on; the "Sing in 1" countdown
appearing before an eighteen-second gap; a manual scroll suspending auto-scroll
and offering "Back to playhead"; sing-along mode with large type, the reduced
transport, and the status bar hidden; the LRCLIB sheet refusing to show a search
field until the preference is on, and the same disclosure sentence in both
places; and everything surviving a relaunch, including the resumed playhead.

**The caption fetch shipped hung, and the argument list was why.** `--sub-langs
"en.*,en"` reads as thorough and is the opposite: the wildcard matches every
auto-translated variant a video carries — seven of them on the first song it was
tried against, `en` through `en-es-419` — so yt-dlp downloaded all seven in
sequence, YouTube answered `429 Too Many Requests`, and the retries left the
sheet spinning indefinitely. Requesting plain `en` gets the same file the app
would have kept, in one download and 2.6 seconds. Two further guards went in with
it, because the failure was unbounded rather than merely slow: Python's `urllib`
has no default timeout, and `BundledYTDLP` is an actor, so one stalled socket
holds up every later yt-dlp call including a separation. `--socket-timeout 15`,
`--retries 2`, and `--extractor-retries 1` bound it. The fetch also logs at
`.info` now rather than only through yt-dlp's `.debug` channel, which is not
persisted — there was nothing in the device log to read when this was reported.
The same real caption file showed the section-label rule calling `[♪♪♪]` a
section named "♪♪♪"; a label now has to contain something alphanumeric.

**The vocal-entry count is a microphone and a number, and it floats.** As a
"Sing in 4" pill it was wide enough to land on the line it was counting into on
a small screen. Giving it a row of its own in the list fixed the overlap and cost
more than it saved: inserting a row reflows every line under it, so the words
move under someone who is mid-phrase. Holding the text still is worth more than
the count having somewhere uncontested to sit, so it floats as before and the
words came off it instead. What is left is small enough to clip a sliver of the
most-dimmed line, and the sentence it used to spell out is what VoiceOver hears.

**The lyrics menu could not be tapped while a song played, and the cause was
older than this phase.** Its "Save N Sections" item computed the count from
`player.duration` and `player.practiceSettings` — and reading either inside the
menu's content means re-reading it whenever it changes. `playbackState` moves
ten times a second by design, since the transport needs the position; but
`practiceSettings` was moving at the same rate for no reason at all.
`persistPracticeSettings()` assigned `lastPosition`, `playbackRate`, and
`pitchSemitones` *before* consulting the throttle, so Phase 1's throttle covered
the disk write and not the `@Observable` mutation. Everything watching practice
state re-evaluated at 10 Hz, and SwiftUI rebuilt the open menu under the user's
finger, swallowing the tap. It worked as soon as they paused.

Both halves are fixed. The three assignments moved behind the throttle guard, so
practice state now mutates when it is written rather than when it is asked to
be; nothing outside `StemPlayer` reads those three from there, because the
transport takes all of them from `playbackState`. And the menu answers "how many
sections do these lyrics describe" from the lyrics alone, deferring every read
of the player to the moment of the tap — `addSavedSections` already drops
overlaps, so the duplicate check did not need to be in the menu. The general
lesson is worth keeping for Phases 7–9, which will add more menus over a playing
song: **anything a menu reads while open, it re-reads when that value changes.**

**The caption fetch is as fast as it is going to get, so the fix is telling the
user what it is doing.** Measured against the bundled yt-dlp: 0.94 s to import
the zipapp into Python, 1.6 s for YouTube's extraction, 0.1 s for the subtitle
file itself. The first two are fixed costs, they are the same ones a separation
pays before it starts, and on a phone's CPU they are several times larger — there
is no wasted work left to remove. What was missing was any account of the wait:
an indeterminate spinner, no cancel, and — because captions share the one queue
with separation — no way to tell "waiting behind a separation" from "hung". The
sheet now shows the job's own status and progress, offers Stop, and says up front
that this uses the same downloader as separation. `youTubeCaptions` returns the
`AnalysisOutcome` whole rather than flattening it, because a fetch the user
stopped and a video with no captions are different things to say and only one of
them is news.

**The primary action left the scroll.** On the import screen the Create button
was the last item in a card sitting under four outcome cards that are taller
than a phone, so someone who had just pasted a link saw the choices and no way
to act on them. `ImportActionBar` is pinned with `safeAreaInset` — the same
place the transport occupies once a song is open, and now the same rule on both
screens: the one thing to do next is never the thing below the fold.

The progress card had the same problem one step later, and worse: starting a
separation replaced a visible button with a progress bar that was itself below
the fold, so the screen looked as though nothing had happened. It shares the
pinned bar now and *replaces* the action while a job runs, which costs nothing —
the action is disabled during a job anyway — and means the only thing on the
screen the user still cares about is the only thing pinned to it. The URL
field also grew a clear button, which meant drawing the field rather than using
`.roundedBorder`: overlaid on a system-styled field the button sits on top of
the text, and a YouTube URL is long enough to run straight under it.

**Not verified.** The caption path was diagnosed and fixed by running the exact
argument list against the bundled `yt-dlp` on a Mac, not through the embedded
interpreter on device; the parser is unit-tested against both a rolling
auto-caption fixture and the real manual track that exposed the `[♪♪♪]` case. An
LRCLIB search *was* run and round-tripped its way to "no matches" — request,
headers, and decode are exercised, but the path where a match comes back and is
applied is not. Sing-along in landscape draws, but the simulator's rotated
coordinate space made driving it unreliable, so it is untested. And nothing here
had a device pass: haptics — now including the selection confirmation — and
VoiceOver reading order are still what the next one owes, alongside Phase 4's.

---

## Phase 7 — Beat and downbeat grid

**Goal:** A musical time grid, with no model download. Upgrades the metronome and
looping as well as enabling chords.

### Work

- [x] Compute a spectral-flux onset envelope from the drums stem. Streamed and
      downmixed at the file's own rate, so no whole-song resample is needed.
- [x] Estimate tempo by autocorrelation or comb filtering, with a log-normal
      prior centred near 120 BPM. **Autocorrelation and the prior only** — the
      comb sum was built, measured, and removed; see the outcome.
- [x] Track beats with Ellis-style dynamic programming.
- [x] Estimate the downbeat phase from bass-onset energy and chord-change
      likelihood. Bass-onset energy plus the full-band envelope at half weight;
      chord-change likelihood waits for Phase 8, which is what computes it.
- [x] Store `BeatGrid` as an explicit beat list so tempo drift is representable.
- [x] Make BPM, first-downbeat offset, and beats-per-bar user-editable, with
      `isUserEdited` respected on re-analysis. Halve and double are their own
      controls, because they are the correction the detector actually needs.
- [x] Auto-align the metronome from the grid, replacing manual alignment as the
      default while keeping manual override.
- [x] Snap A–B loop boundaries to bar lines, with a modifier to set them freely.
- [x] Derive count-in from the detected tempo and schedule it in the audio graph
      instead of `Task.sleep`.
- [x] Express the tempo ramp in BPM as well as percentage. The transport's speed
      menu too, which is where speed is usually changed.
- [x] Detect and report low-confidence grids rather than showing a wrong tempo.

### Acceptance criteria

- [x] On steady-tempo material the grid is within ±15 ms of hand-tapped beats.
      Measured against machine-placed beats, which is a stricter reference than
      a hand-tapped one: **5.2 ms mean, 6.5 ms worst case** across a 20-second
      click track, and 5.6 ms on the seeded song in the simulator. The error is
      a consistent lead, not scatter — spectral flux starts rising before the
      transient peaks.
- [x] A wrong grid can be corrected in under three interactions. The wrong grid
      this phase actually produced took **one**: Half Speed.
- [x] Bar-snapped looping selects musically sensible boundaries. Verified in the
      simulator: A and B landed on 12.554 s and 24.613 s, both exactly detected
      downbeats, five bars apart.
- [x] The count-in no longer drifts and matches the song's tempo. Every click is
      an exact multiple of the beat by construction and the music starts at the
      end of the last one, both unit-tested; **confirmed by ear** against a real
      song, counting in at that song's detected tempo and handing over to the
      music in time.
- [x] Analysis failure leaves the manual metronome fully functional. The click
      itself was **confirmed by ear** on a real song, following the detected
      grid. The failure half stays true by construction rather than by trial:
      with no grid, or one below the confidence bar, every effective value falls
      back to the hand-set one and nothing snaps. Those fallbacks are not
      unit-tested — they live on `StemPlayer`, which the suite does not
      instantiate — and the "no steady beat found" path has not been seen on
      real material.

### Outcome

**New files.** `BeatGrid.swift` is the model and every question that can be
asked of a grid — where the nearest bar is, what the tempo is, whether it
drifts, what a correction does to it. `BeatDetector.swift` is the analysis, as
plain functions over arrays. `BeatAnalysis.swift` holds the queue job and
`BeatGridStore`, the per-song owner, in the shape Phase 6 established for
lyrics.

**The grid is a list of beats, not a tempo and an offset.** Real performances
drift, and a grid that could only say "112 BPM from 0.31 s" would be a bar out
by the end of a song that slows into its chorus, with no way to express it. The
tempo the user sees is the median interval derived back out — the median
because one missed beat moves a mean by several BPM and a median not at all.

**Correcting the tempo regenerates the list, and that is the honest trade.** A
user who says "it is 96, not 128" is rejecting the detected beats, not asking
for them to be nudged; the grid becomes uniform at 96, anchored at the downbeat
they already have. The consequence is visible in the simulator: halving 199.05
gives a uniform grid at 99.5 BPM, and 0.5% is 120 ms of drift by the end of a
four-minute song. Detecting again is the fix, and it is one tap away.

**Double tempo is the failure mode, and the comb filter was making it worse.**
The first implementation scored each candidate period with its own multiples —
`acf(t) + 0.5·acf(2t) + 0.25·acf(3t)` — which reads as thorough and is
systematically wrong in one direction: a song periodic at its beat is also
periodic at every subdivision of that beat, so the faster reading always
collects the same harmonics. Removing it left the log-normal prior, which
penalises 200 BPM against 100 by about 25%, and that is not always enough:
against a seeded track with hi-hats on every eighth, autocorrelation at the
eighth still won and the app reported 199 BPM for a song at 100. Two things
came out of that. `resolvedTempo` halves a tempo above 140 BPM when the placed
beats *alternate* in strength — the signature of counting the hats rather than
the beat — which fixes the clean cases and is unit-tested in both directions.
And the sheet grew Half Speed and Double, because this is a known-hard research
problem, it will keep being wrong on some songs, and the product answer to that
is one tap rather than a better guess.

**Ellis's dynamic program needed two things his paper assumes.** The score has
to *accumulate* along the path rather than being blended with it; the first
draft used a running average, whose maximum sits wherever the drummer hit
hardest, so tracking a 20-second fixture stopped at 12.9 s and returned 22 of
33 beats. And the trace has to be trimmed at both ends: the path has to start
somewhere, and with nothing behind it the first frame of the song scores as
well as anything, so every grid began with a beat at 0:00 that nothing was
played on — 290 ms from the nearest real one. With the accumulating form and
librosa's local-maximum rule for the last beat, the same fixture returns
exactly 33 beats and the worst error falls from 290 ms to 6.5 ms.

**Frames are centred on their own timestamps.** An uncentred STFT reports a
transient up to a whole window late, which at a 23 ms window would spend the
entire error budget before the tempo was even estimated. What remains is a
consistent 5 ms *lead*, because flux rises as the transient enters the window
rather than at its peak. It is inside the budget and it is systematic, so it
could be compensated with a constant if a device pass says it is audible.

**The count-in is scheduled, not slept through.** It used to be
`AudioServicesPlaySystemSound` in a loop with `Task.sleep(1s)` between clicks:
one click per second whatever the song's tempo, and every click carrying the
previous one's scheduling error. It is now a `CountInPlan` placed into the audio
graph at absolute times, at the song's own tempo, with the stems started exactly
one count-in later on the same host-time line — so the music arrives where the
last click said it would, rather than a moment after the app noticed the count
had finished. Two consequences worth recording: the count-in got a player node
of its own, because sharing the metronome's node means sharing its gain and a
user who has turned the click down would be counted in silently; and the
metronome node now starts when the count-in does, so the song's click plan is
offset by the count-in's length on that node's clock.

**A hand correction switches off following the grid.** Setting a BPM or aligning
the click by hand sets `metronomeFollowsGrid` to false, because anything else
would make the correction temporary — the next detection, or simply reopening
the song, would put the detected number back. The toggle to follow again is in
the same sheet.

**No memory gate on this job.** Phase 5 built one for model-backed work, and
this is the tier that has no model: it holds one mono copy of one stem at a
time, about forty megabytes for a four-minute song, which is the same order as
the waveform overview that has always run unguarded. A gate here would also
refuse the work in every simulator, where `os_proc_available_memory()` reports
zero.

**Simulator verification.** Driven against a seeded 4-stem track built for this
— 40 s at 100 BPM in 4/4, first downbeat at 0.5 s, kick and snare on the
backbeat, hats on every eighth, bass on the one and the three. Confirmed:
detection running through the shared queue and writing `beats.json`; the
detected downbeat at 0.494 s against a true 0.500 s; Half Speed correcting
199 BPM to 100 in one tap and marking the grid as the user's; bar lines drawn
on the transport timeline; A and B snapping to exact downbeats; the Click sheet
reporting "at 100 BPM, accenting every 4 beats, aligned to the song's first
downbeat"; the count-in sheet reporting the same tempo, and a four-click count-in
running into playback without a stall.

**The simulator pass found one gap in the wiring**, not in the analysis: a
detection that fails had nowhere to say so, because the store's error was only
readable inside a sheet the user may have closed while the job ran. It is a
caution banner in Studio now, like the practice-target notice.

**Heard, on a real song.** The count-in counts in at the song's tempo and hands
over to the music in time, and the click follows the detected grid. Those were
the two things the simulator could show but not settle.

**Still unverified.** The grid against a range of real recorded material —
drift, rubato, live drumming, and sparse arrangements are where a detector
earns its confidence figure, and one song is not a range. The click is also
still a *steady* click: it takes the median tempo and the first downbeat from
the grid and does not follow the beat list itself, so a genuinely drifting take
will hear it walk away by the end. Bar lines and A–B snapping do follow the
beat times, so a drifting song shows the difference between them on screen.
Phase 4's haptics and VoiceOver reading order are still owed by a device pass.

---

## Phase 8 — Chord detection, bundled tier

**Goal:** Useful chords with no download, honest about accuracy.

### 1. Feature extraction

- [x] Build the analysis mix: `0.8·bass + other + guitar + piano`, excluding
      vocals and drums; record `sourceStemSet` with the result.
- [x] Resample to 22.05 kHz mono. Streamed through one `AVAudioConverter` per
      stem rather than read whole and converted whole.
- [x] Compute a harmonic pitch-class profile with overtone suppression.
- [x] Compute a separate bass chroma from the bass stem over ~40–250 Hz.
- [x] Average chroma within beats from the Phase 7 grid.

### 2. Classification

- [x] Define templates for `{maj, min}` first, extending to `{dom7, min7, maj7,
      sus4, dim}` plus no-chord. The five extensions carry a prior penalty — see
      the outcome.
- [x] Score frames by cosine similarity, with a bass term rewarding root and
      inversion matches. The bass term is *relative* to the average chord, which
      is the only form of it that stays neutral when the bass says nothing.
- [x] Decode with an HMM: strong self-transition prior plus key-conditioned
      transition probabilities.
- [x] Estimate key by Krumhansl–Schmuckler correlation, cross-checked against
      the decoded chord histogram.
- [x] Emit `ChordSegment`s snapped to beats and bars.

### 3. Display

- [x] Bar-grid view, four bars per row, section labels, current bar highlighted,
      auto-scrolling ahead of the playhead.
- [x] Ribbon view scrolling under a fixed "now" line.
- [x] Next-chord preview with a beat countdown.
- [x] Tap a bar to seek; drag across bars to set a bar-snapped loop.
- [x] Dim low-confidence chords; long-press to correct one. One gesture does
      both — see the outcome.
- [x] Transpose displayed chords by `player.pitchSemitones` so the chart always
      matches what is heard.
- [x] Detect material the templates cannot model and say so, instead of
      displaying confident nonsense.

### Acceptance criteria

- [~] Analysis of a 4-minute song completes in under 30 seconds without
      blocking playback. **8.9 s in the simulator** on a seeded four-minute
      song, and playback ran through a re-analysis without a stall or a dropped
      frame. A phone's CPU is slower and this has not been measured on one.
- [x] Chord display remains correct at every supported transposition. The chart
      and the key name are transposed on display and stored untransposed;
      confirmed in the simulator by correcting a chord at +2 and finding the
      correction in the song's own key at 0. Unit-tested through a round trip.
- [x] Any chord can be corrected, and corrections survive re-analysis. Confirmed
      in the simulator: a corrected bar kept its chord and its mark through a
      rerun that replaced every other bar, with the banner saying so.
- [x] Unreliable results are labelled rather than shown as facts. A chart below
      the confidence bar is badged "Uncertain", individual chords below it are
      dimmed rather than hidden, and a song the templates could not fit says so
      outright.

### Outcome

**New files.** `Chords.swift` is the model and every question that can be asked
of it — what a chord is called in this key, what it becomes transposed, which
bar it lands in, what a correction does to the chart. `ChordDetector.swift` is
the analysis, as plain functions over arrays. `ChordAnalysis.swift` holds the
queue job and `ChordStore`, the per-song owner, in the shape Phase 6 established
for lyrics and Phase 7 for beats. `ChordsStage.swift` is the two views, the now
card, and the correction sheet.

**Vocals and drums are excluded, and that is the whole first stage.** A sung
melody is not the harmony and frequently disagrees with it; drums put broadband
noise into all twelve pitch classes at once. What is left — bass, other, guitar,
piano, or a two-stem separation's instrumental — is summed at 22.05 kHz mono
with the bass at 0.8, because a bass fundamental in a per-frame-normalised
profile is loud enough to turn every chord into its own root. The result records
which stems it actually heard, so a chart taken off isolated instruments can be
told from one taken off a single instrumental stem.

**Overtone suppression is what stops one note reading as a chord.** A low C with
four harmonics has energy at C, G, and E: a plain bin-to-pitch-class histogram
of a bass line prints a triad nobody played. Only spectral peaks contribute, and
each peak contributes to the pitch class of every fundamental it could be a
harmonic of, decaying by 0.6 per harmonic. Unit-tested in both directions — a
triad's three notes come out on top, and a lone note stands 1.5× clear of
everything else.

**The bass term had to be relative, and the first version quietly printed
silence.** Scoring `(1 - w)·similarity + w·bassAgreement` scales every chord
down by `w` when the bass says nothing — which is exactly what happens on a
two-stem separation, in an intro, or anywhere the bass rests — while the
no-chord state keeps its constant. The whole song came back as N.C., and the
test caught it before the simulator did. The bass now contributes how much more
it supports *this* chord than the average chord, which is zero when it is silent
and zero when it is uninformative, and is the only thing a bass note can
honestly settle anyway.

**The extensions pay for themselves.** A seventh differs from its triad by one
pitch class, so on a noisy beat the richer template wins on a coincidence and
prints a chord nobody played. Major and minor score at par; sus4 pays 0.02,
the sevenths 0.03, diminished 0.04. That is a tuned constant and it is honest
about being one.

**The decoder's costs are in score units, not log-probabilities.** Staying on a
chord is free, changing costs 0.22, and changing to something outside the key
costs 0.08 more. Cosine similarities are not calibrated likelihoods, so
multiplying them by real transition probabilities would be arithmetic with no
meaning behind it. Because the only alternative to staying is "the best other
state", each step is linear in the number of states rather than quadratic, which
is what makes 85 states over a four-minute song instant.

**Two defects came out of the first simulator run, and both were about time
rather than pitch.** The chords were right — C Am F G, in C major — and every
change was landing a beat early. The chromagram's frames were not centred on
their own timestamps, so each frame described the 186 ms that *followed* it and
every frame in the last beat of a bar already contained a third of the next
chord. Phase 7's beat detector centres its frames for the same reason and this
did not; it does now, and the boundary error fell from ~600 ms to **5 ms**. The
second was circular reasoning: bar snapping ran against the grid's existing
downbeat phase, so the changes were pushed onto it and then agreed with it by
construction, which meant the chord-derived phase correction could never fire.
The phase is now read from the raw decoded path, before anything is moved.

**Harmony is the third witness to where the bar starts.** Phase 7 estimated the
downbeat from bass onsets and the full-band envelope and recorded that
chord-change likelihood was owed by this phase. It is here: the phase that
collects the most chord changes is handed to `BeatGridStore`, which takes it
only when the grid is reliable, not the user's own work, and actually different,
and says so when it does. On the seeded song it moved the bar line three beats
and turned a chart of half-bars into sixteen bars of one chord each.

**Holding a bar means one of two things, and the finger says which.** The plan
asked for both long-press-to-correct and drag-across-bars-to-loop, and a
`contextMenu` cannot coexist with the long-press-sequenced drag the lyrics
reader already uses. So it is one gesture: hold one bar and let go to correct
that chord, hold and drag across several to loop them. The loop goes through
`setLoopBoundaryA`/`B` — the transport's own calls — so a loop set from the
chart and one set by hand are the same loop, and it is bar-snapped by
construction rather than by rounding.

**A correction is stored in the song's key, not the key being heard.** The chart
is transposed on display by `player.pitchSemitones`; a correction made at +2 is
transposed back before it is written. Otherwise returning to the original key
would show the user their own correction, wrong. Confirmed by entering Dsus4 at
+2 and finding Csus4 at 0.

**Re-analysis is not all-or-nothing, unlike the beat grid.** A grid the user
corrected wins outright because a tempo is one number; a chart is hundreds of
independent facts, and someone who fixed the bridge should still get a better
verse out of a rerun. The fresh analysis wins everywhere except the ranges the
user has touched, which are written back over it, splitting neighbours rather
than deleting them.

**`RealFFT` is shared now.** It was file-private to `BeatDetector.swift`; chord
analysis needs exactly the same thing at a different window length, so it is
internal and there is no second copy.

**Simulator verification.** Driven against two seeded 4-stem tracks built for
this — 100 BPM in 4/4, first downbeat at 0.5 s, C–Am–F–G one chord per bar, with
the vocal stem carrying a melody on the third to prove it is excluded. On the
four-minute one: **100 of 100 bars correct**, key C major, confidence 0.98,
boundary error 5 ms worst case, analysis in **8.9 s** with playback running
through it. Also confirmed: the empty state naming the stems it will listen to;
one tap running beat detection and chord analysis in order; the bar grid
auto-scrolling and marking the current bar; the ribbon carrying the current
chord under the now line; the next-chord preview counting down in beats; the
chart reading D–Bm–G–A at +2 with the header saying "D major · as heard";
correcting a chord and finding it in the song's own key; a held drag across four
bars setting A 0:00 – B 0:10 with looping on; a rerun keeping the correction and
saying so; and everything surviving a relaunch.

**The Dynamic Type pass found one defect**, the same shape as Phase 4's: the now
card's current chord was a fixed 40-point size while everything around it
scaled, so at accessibility sizes the *next* chord was drawn larger than the
chord being played — the one hierarchy that card has, inverted. Both it and the
correction sheet's preview are text styles now.

**No memory gate**, for the reason beat analysis has none: this is the tier with
no model. It holds one mono copy of the analysis mix at 22.05 kHz, about twenty
megabytes for a four-minute song, and a gate would refuse the work in every
simulator, where `os_proc_available_memory()` reports zero.

**Still unverified.** Real recorded material, which is where a chord detector
earns its confidence figure: everything above is a synthetic fixture with
unambiguous triads, and it says nothing about how the templates cope with a
distorted guitar, a dense mix, or a song that modulates. Nothing here has had a
device pass, so the 30-second budget is a simulator number and the haptic on a
committed selection has never fired on a Taptic Engine. VoiceOver reading order
across the bar grid is untested, and is now owed by the next device pass
alongside Phase 4's.

---

## Phase 9 — Simplification, capo, and the Sheet view

**Goal:** Make the chords playable by the person holding the guitar.

### Work

- [x] Add a complexity level: **Full**, **Simple** (triads), **Beginner** (open
      shapes), **Power** (root and fifth). Persist per song.
- [x] Add independent toggles: hide slash/inversions, merge repeated chords,
      hide sub-beat passing chords.
- [x] Implement capo suggestion: search capo 0–7 against an open-shape
      vocabulary, scoring by easy-shape coverage and barre penalty.
- [x] Mark every simplified chord; tap reveals the detected chord. A press on
      the now card rather than a tap on a bar — see the outcome.
- [x] Add reverse transposition: choose a playable key and shift the audio to
      match.
- [x] Bundle a chord-shape database keyed by root and quality, with open and
      barre voicings.
- [x] Add a fretboard diagram sheet and a chord-vocabulary strip for the song.
- [x] Build the **Sheet** stage: chord symbols positioned over lyric syllables,
      exact with word-level timing and interpolated otherwise.

### Acceptance criteria

- [x] Beginner level produces a chord set playable in open position, or states
      that it cannot. Both halves are unit-tested, and the sheet names the
      chords it could not place in open position rather than implying the level
      succeeded.
- [~] A capo suggestion, when accepted, yields chords that sound correct against
      the transposed backing. The arithmetic is unit-tested — capo 3 on B♭–E♭–F–Gm
      returns exactly G–C–D–Em — and the chart, the sheet, and the shape sheet
      all print shapes and name the sounding chord. **Not verified against a
      guitar**, which is the only test that settles "sounds correct".
- [x] Simplified chords are always distinguishable from detected chords. A
      hollow ring on the bar, the ribbon chip, and the sheet symbol; the now card
      says what it was simplified from and reveals it under a press.
- [~] The Sheet view is legible at arm's length while holding an instrument.
      Legible in the simulator at default and accessibility sizes, with its own
      size control on top of Dynamic Type. **Arm's length is a device
      judgement** and has not been made on hardware.

### Outcome

**New files.** `ChordShapes.swift` is the shape catalogue and the question
"how hard is this chord?". `ChordPlayability.swift` is every transformation of
a chart and both searches — capo and key. `ChordShapeViews.swift` draws chord
boxes, the vocabulary strip, and the Playability sheet. `ChordSheet.swift` lays
words and chords out together, and `SheetStage.swift` renders it, wrapping
included.

**Simplification is a lens, never an edit.** `chords.json` is untouched by all of
it: the Chords stage transposes the stored chart to what is being heard, then
puts the song's complexity, toggles, and capo over it, and each changed segment
carries `detected` — the chord that was actually heard. `detected` is
deliberately outside `ChordSegment.CodingKeys`, so a simplified chart *cannot*
be persisted as though it were the analysis, and a test asserts the word never
reaches the file. Corrections made on a simplified chart are opened against the
un-simplified copy, so someone who fixes a bar that is printed as G is editing
the G7 the detector heard.

**The power chord is a quality the detector may not use.** `ChordQuality.power`
exists so the Power level has something to *say*, and `ChordQuality.detectable`
— everything except it — is what the decoder's state list is built from. A
two-note template fits almost anything; offering it to the decoder would print
fifths over a song full of triads.

**The order of the transforms is the whole correctness argument.** Transposition
is about the audio and comes first; simplification and the capo are about the
hands and come second. Done the other way round, the Beginner search would look
for open shapes in a key nobody is hearing. The capo is applied last and on its
own — the shape a player grips is the sounding chord moved *down* by the capo —
which is why the chart, the vocabulary strip, and the sheet all print shape
names while the shape sheet says what each one sounds.

**The shape catalogue is hand-written, and small on purpose.** About thirty open
shapes plus two movable forms — the E shape on the sixth string and the A shape
on the fifth — generated for any root. A generator would produce every
mathematically valid voicing, most of which nobody plays; what a person learning
a song needs is the shape a teacher would show them. Two tests hold it honest:
every open shape sounds only notes of the chord it claims (with the fifth allowed
to be missing, as the standard C7 grip drops it), and every entry in the open
table really is open position.

**Both searches are weighted by time, not by count.** A song with thirty seconds
of G and two of B♭ is a G song, and a capo that fixes the B♭ at the cost of the G
is the wrong answer — there is a test for exactly that. A capo pays 0.012 per
fret and a key shift 0.015 per semitone, so neither is suggested for a rounding
difference: fitting a capo is work, and shifting the audio smears the stems.

**Beginner reports what it cannot do.** When no substitution has an open shape —
B diminished, whose minor triad is also a barre — the chord is left as it was
heard and named in the Playability sheet, in the same terms the chart is printed
in. Printing an E in place of an F because E is easy would be the app lying about
the song.

**The reveal is a press, not a tap.** The plan asked for tap-to-reveal, and in
the bar grid a tap already seeks — muscle memory Phase 8 signed off on. Holding
the now card shows the chord that was heard for as long as it is held, and lets
go of it afterwards; a mode that stayed on would quietly undo the simplification
the user chose. The vocabulary strip's chord boxes and the correction sheet say
the same thing in full.

**`SheetFlow` exists because a chord sheet is two baselines that wrap together.**
`HStack` cannot wrap and `Text` cannot carry a second row of type above itself,
so the line is split into chunks at the chord positions and laid out by a
`Layout` that measures each chunk against the row width. That last part was a
defect first: measured unconstrained, a line with one chord at its head is a
single chunk and ran off the page at accessibility sizes.

**Simulator verification.** Driven against a seeded 16-bar 4-stem fixture at
120 BPM — C, Am, Fmaj7, G7, with a slash chord in bar 6 and a quarter-second
passing chord in bar 10 — with timed lyrics, two lines of them word-timed.
Confirmed: the four levels and three toggles changing the chart; the passing
chord disappearing and the slash chord losing its bass; capo 1 printing
B–G♯m–E–F♯ with the capo badge, and the beginner warning naming the shapes that
have none; "No capo — 100% of this song is already open shapes" for the
untouched chart, and G major at −5 semitones offered as the alternative; the
vocabulary strip drawing E open, F♯ and B barred at 2, and G♯m at 4; the shape
sheet saying "with the capo at fret 1 this sounds F"; the now card reading
"E, simplified from Emaj7"; the Sheet stage placing chords over the words with
section labels and instrumental chords on their own row; and every one of these
settings surviving a relaunch.

**The Dynamic Type pass found four defects**, all of them at
accessibility-extra-large and all fixed: the header's badges truncated to "…"
beside a fixed 110-point picker (they now take their own row), the vocabulary
strip was squeezed to half a chord box (its height is stated, and the boxes grow
with the text), the chord boxes clipped their own open and muted marks at 54
points (the marker row and the string inset scale with the box), and the sheet's
lines ran off the right edge.

**Not verified.** No device pass, so the haptic on accepting a capo has never
fired on a Taptic Engine and "legible at arm's length" is still a simulator
judgement. Nothing here has met a real guitar, which is the only way to settle
whether an accepted capo suggestion sounds right against the transposed backing.
VoiceOver reading order across the chord boxes and the sheet joins the debt
Phases 4 and 8 already owe.

---

## Phase 10 — Capacity, model management, and library integrity

**Goal:** Make the app safe to download large optional models into. This is the
gate in front of Milestone E, not optional polish — Whisper alone can be
~470 MB.

Absorbs `IMPROVEMENTS_PLAN.md` items 4, 6, and the required slice of 19.

### 1. Capacity and storage policy (item 4)

- [x] Estimate required space before downloading, separating, recording,
      exporting, and analysing, including staging overhead.
- [x] Block operations that cannot safely complete, using system capacity APIs
      and keeping a reserve rather than consuming all free space.
- [x] State how much additional space is needed in the error copy.
- [x] Exclude reproducible assets from backup: optional models, derived stems,
      **and downloaded originals**, which are re-fetchable from their source URL
      and are therefore cache. Performances are user data and are preserved.
- [x] Put the user's own work behind an explicit preference, off by default.
      Added after the phase's first pass, on the user's call — see "Backup
      became a preference" below.
- [x] Allow originals to be evicted under storage pressure, with clear copy that
      re-separating will re-download. Offered as an explicit action rather than
      done automatically — see the outcome.
- [x] Show storage totals by Originals, Separations, Performances, Models,
      Analysis, and temporary data.

### 2. Library integrity and recovery (item 6)

- [x] Distinguish valid, recoverable, incomplete, and corrupt library folders,
      now including `lyrics.json`, `chords.json`, and `beats.json`.
- [x] Reconstruct safe metadata where IDs, filenames, duration, or dates can be
      derived reliably.
- [x] Quarantine unrecoverable entries rather than silently skipping them.
- [x] Never let a damaged analysis file make its song unopenable.
- [x] Record structured diagnostics without exposing private media metadata.

### 3. Settings, completed (item 19)

The skeleton landed in Phase 4 and the lyrics preferences in Phase 6. This
phase adds everything that depends on downloadable assets.

- [x] **Downloads & Models**: list every installed optional asset — four
      separation models, plus the Whisper and chord models from Milestone E —
      with size, install state, and a delete action.
- [x] **Storage**: totals by Originals, Separations, Performances, Models,
      Analysis, and temporary data, with cleanup actions.
- [x] Expose cached-originals eviction here, with copy explaining that
      re-separating will re-download.
- [x] **Privacy & data**: what leaves the device and when, and the backup policy
      per category, plus the toggle that decides two of those categories. Keep
      it consistent with the README.
- [x] **Diagnostics**: export the structured library-integrity report from
      section 2 without exposing private media metadata.
- [x] Keep per-item content deletion in Library; Settings owns aggregates and
      app-level assets, not individual songs or takes.

### Acceptance criteria

- [x] Operations fail before starting when capacity is insufficient, with copy
      stating the shortfall. Unit-tested against an injected reading at, above,
      and below the threshold, including that exactly enough space is still
      refused because of the reserve.
- [x] A partial model directory is never reported as installed. Already true
      from Phase 2's manifest; this phase adds the removal path, which unlinks
      the manifest before the artifact so an interrupted removal fails the same
      way.
- [x] Corrupt fixtures produce explicit recoverable/unrecoverable results, and
      no item disappears without a diagnostic record. Sixteen fixtures cover
      all four states across the three entry kinds; every quarantine writes a
      finding with its reason into the stored report.
- [x] Every downloadable asset can be inspected and deleted from Settings.
      Confirmed in the simulator against a seeded install: size and state shown,
      removed on confirmation, row back to "Not downloaded".
- [~] Storage totals match on-disk usage within an agreed tolerance. The totals
      are the library index's own byte counts plus a direct walk of Models,
      quarantine, and staging, and they moved by the expected amount on every
      simulator action. **No tolerance was agreed or measured against `du`**,
      which is why this is not `[x]`.

### Outcome

**New files.** `StorageCapacity.swift` holds the gate — free space, the
reserve, the per-operation estimates, the refusal, and `CachedOriginals`.
`LibraryIntegrity.swift` holds the four-state classification, the
reconstruction rules, quarantine, the storage breakdown, and the diagnostics
text. `SettingsStorage.swift` holds the four screens and the one object behind
them. `StorageCapacityTests.swift` and `LibraryIntegrityTests.swift` cover both.

**The gate is a refusal, not a failure, and it says the number that helps.**
`StorageCapacity.require(bytes:for:)` compares against
`volumeAvailableCapacityForImportantUsage` — larger than raw free space,
because it counts what iOS will purge for something the user asked for — and
subtracts a 300 MB reserve that the app will not spend whatever it is asked to
do. The message names the operation, the size it needs, and the shortfall:
"free up about 420 MB and try again" rather than "the operation could not be
completed". It is wired into the download, the separation, the model install,
the take, the export, and every analysis write.

**The estimates come from what the app writes, not from a guess.** Separated
stems are 32-bit float stereo WAV at 44.1 kHz — 352,800 bytes per second per
stem — which is why a separation is the one worth checking: a four-minute song
arrives as a few megabytes and leaves as 340 MB, or 500 MB at six stems. A
model asks for its *install* footprint rather than its download size, because
MDX23C's archive, its extracted package, and the compiled model all exist at
once.

**Eviction is an action, not a policy.** The plan says to allow originals to be
evicted "under storage pressure". Doing it automatically would mean deleting
the user's downloads on a schedule they cannot see, so Settings offers it
instead, in two scopes: the originals that already have a separation, which is
the cheapest thing in the library to give up, and all of them. What makes it
defensible at all is that it takes only the audio: the folder, its metadata,
its practice settings, its loops, and its corrected analysis stay exactly where
they were, and `HistoryOriginal.audioURL` became optional so an evicted song is
still a song in the Library rather than an entry that vanishes. `LibraryIndexer`
no longer requires the audio file to exist, and Studio's `separate(original:)`
falls back to the URL path when it is gone.

**Backup became a preference, off by default.** The first pass shipped the
policy as a constant: performances and practice state backed up, everything
reproducible excluded. Asked whether the user should get a say, the answer was
yes and off by default, and that was the call taken over a recommendation to
default it on. The reason for the recommendation is worth keeping in the record
rather than losing with the argument: performances are the one thing in the
library nothing can reproduce, so a restore that happens before anyone finds
the toggle loses every take. Settings therefore says so in the footer rather
than describing the toggle neutrally, and turning it on re-applies across the
existing library rather than governing only what is recorded afterwards —
`isExcludedFromBackup` is written as `false` as deliberately as it is written
as `true`, or the switch would only go one way.

What the preference does **not** do, and cannot: switch iCloud Backup itself.
The app only marks its own files. iOS already has a per-app backup switch that
covers the whole container, and the privacy screen points at it.

**Backup was only half applied, and the missing half was the expensive half.**
Downloaded originals and models were excluded; separated stems never were,
which put hundreds of megabytes per song into the user's iCloud quota to save
work a re-separation redoes. `applyBackupPolicy(toSeparation:)` excludes the
stems and the waveform overview and nothing else, so a `practice.json` that
fell back to living in a track folder is still backed up. Because the rule
changed, `applyBackupPolicyAcrossLibrary()` re-applies it across the whole
library at launch rather than only to entries written from now on.

**Discovery used to answer one question and give one answer.** A folder whose
metadata would not decode returned `nil`, vanished from the Library, and left
nothing anywhere saying it had existed — the Phase 0 outcome recorded exactly
this as something Phase 10 would replace. There are four answers now, and the
rule for each is what the *files* can be made to say:

- A separation names its own model. No two models this app runs produce the
  same set of stems, so a lost `track.json` is rebuildable from the directory
  listing: the folder's name is the ID, the file dates are the date, and
  `{vocals, instrumental}` is unambiguously the two-stem output.
- A performance's duration is in its microphone file, so a lost
  `recording.json` costs its title and its source track, not its audio.
- An original with no metadata keeps its audio and its ID and loses its
  provenance. A source URL is not derivable and is not invented — which is why
  `OriginalMetadata.sourceURL` became optional rather than being filled with a
  plausible guess that the app would then offer to re-download from.
- Anything with neither a description nor content is moved to `Quarantine/`
  rather than deleted, and appears in the report with the reason it went.

**"Incomplete" is the distinction that keeps this safe.** A separation missing
one stem, or an original whose audio has been evicted, is short rather than
damaged, and quarantining either would take something working away from the
user. Those stay exactly where they are and are reported. An evicted original
is `valid`, not `incomplete`, whenever its source is known: that is a cache
behaving as designed, and calling it a fault would put a permanent orange badge
on Settings for anyone who used the reclaim button.

**A damaged analysis file could never stop a song opening — that was already
true.** Reads are non-throwing by construction from Phase 5, so a truncated
`chords.json` reads as no result. What it could do is sit there forever
suppressing the analysis the app would otherwise redo, so the pass removes it
and names it in the report. The report names *files*, which are the app's own
output; it never names a song.

**The diagnostics report describes the library without describing its
contents.** Every entry is a folder UUID, a kind, a size, a file count, a
status, and a reason. A test asserts that a seeded title, source URL, and media
filename are all absent from the exported text, because the whole point of the
export is that the user can send it somewhere.

**Found by the tests.** The backup toggle looked like it would not turn off
again: flipping the preference on and re-reading the flag still said excluded.
The write was correct and the *read* was stale — a `URL` that has already been
asked for a resource value can answer from its own cache, so the test was
measuring its last question rather than the file. Only the test read back, so
nothing shipped wrong, but it is the kind of thing that would have looked like
a real bug on device.

**Found by the simulator pass.** The storage totals lagged by one refresh:
`StorageSettingsModel` measured the snapshot it was handed, which was taken
before its own eviction, so the first tap freed 2 MB and reported the same
total as before. It takes the `HistoryStore` now and awaits a fresh snapshot
first — `refreshNow()` exists for exactly this, because `refresh()` is
fire-and-forget and that is wrong for a caller that is about to measure.

**Simulator verification.** Driven against a seeded library holding a healthy
original with practice state, an evicted original, a healthy 4-stem separation,
a separation with no metadata, a separation missing a stem beside a truncated
`chords.json`, an unparseable folder, and a performance. Confirmed: the launch
pass repairing the metadata-less separation and quarantining the unparseable
folder; the repaired entry appearing in the Library as "Recovered separation";
Diagnostics reporting 16 entries, 2 problems, 1 repaired, 1 quarantined with
both reasons; Storage showing the six totals and the free figure; reclaiming
the already-separated originals dropping the total by the right amount and the
Library showing them as "Audio removed · separating downloads it again" with
their play and share actions explained rather than merely dimmed; a seeded
model install listed with its size and removed on confirmation; and the privacy
screen's per-category backup table.

**Not verified on device.** Nothing here has run on hardware. The two things
that would behave differently are the ones that matter most: the simulator's
volume is the Mac's, so `volumeAvailableCapacityForImportantUsage` says nothing
about what an iPhone would report, and a real low-space refusal has therefore
never been seen. VoiceOver reading order for the four new screens is untested,
as it is for Phase 4's.

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

## Phase 13 — Separation backend performance and memory

**Goal:** Make the two vocal models as fast and as safe as their reputation
says they are. Unscheduled: nothing else depends on it, and every song can
already be separated without it.

Raised by a user run of **Vocals + Backing (MDX23C InstVoc HQ)** that took
*longer* than Balanced 4-stem on the same song while Xcode reported over
2.5 GB in use. Both observations are explained by the implementation rather
than by the model, and both are fixable here.

### 1. The spectral transform is the bottleneck

`MDXVocalSeparator` does per chunk, in app code, what `CoreMLWaveformSeparator`
does not do at all — HTDemucs carries its STFT inside the model graph:

- 1,536 complex 8192-point DFTs, using `vDSP_DFT_zop` (complex-to-complex) on
  real input, which is about twice the necessary work;
- roughly 12.6 million scalar Swift loop iterations for windowing, bin
  mirroring, and overlap-add, including a `reflected()` call per sample;
- an inverse transform run **twice**, because this model returns both stems;
- all of it single-threaded and serialized around each inference.

Its chunks also generate 5.74 s of output against the 4-stem's ~7 s, so a
four-minute song needs about 20% more of them.

- [x] Replace `vDSP_DFT_zop` with a real-to-complex transform.
- [x] Vectorise the window, mirror, and overlap-add loops; hoist `reflected()`
      out of the per-sample path. The mirror is gone rather than vectorised —
      `vDSP_DFT_zrop` gets the conjugate symmetry for free.
- [x] Reuse the scratch buffers across chunks instead of reallocating per call.
- [ ] Measure before and after on the same song and device, and record both.
      **Outstanding, and the reason this phase is not signed off.** The before
      figure no longer exists to measure, so what is available is the after
      figure against the same song on the same device. `SeparationRunMetrics`
      logs elapsed time and the memory headroom a run consumed so the numbers
      can be read straight out of the device log.
- [~] Revisit `speedClass` afterwards. It reads "Moderate" for both vocal models
      now, which is honest about this implementation; "Fastest" was honest only
      about the model. **Left at "Moderate"** until the measurement above
      exists: a speed label is a promise to someone about to spend minutes on a
      separation, and "this should be much faster now" is not a measurement.

### 2. Memory is ungated for the models that need it most

`minimumAvailableMemoryBytes` is set for `htdemucs6s` alone. MDX23C's input is
`[1, 4, 4096, 256]` — 4.2M floats — with attention across 4096 frequency bins,
and the whole song sits resampled in memory for the duration (~85 MB for four
minutes) alongside the per-chunk spectra and stem arrays.

- [x] Give MDX23C and Kim Vocals a real memory requirement, checked by
      `AnalysisQueue` like the 6-stem gate. **The numbers are provisional** —
      2 GB and 1.5 GB, derived below — and are the second reason this phase is
      not signed off.
- [x] Add the `cautionMessage` treatment the 6-stem card has, once there are
      measurements to justify the wording. The wording claims only what is
      known: memory-hungry, and no faster than the 4-stem split.
- [x] Free the resampled mix before the last chunk's output is written, or
      stream it, so peak and steady-state are not the same number. Streamed —
      and for all three separators, not only the MDX pair.
- [ ] Confirm what happens when iOS jetsams a run: Phase 2's staging says no
      partial entry survives, and that has never been tested against a real
      out-of-memory kill.

### 3. Kim Vocals runs everything twice, on the CPU

- [~] `ONNXModelSession` runs CPU-only, and `MDXVocalSeparator` calls it **twice
      per chunk** — once with the spectrum and once negated — to average the
      two. Measure whether Core ML conversion, or an ONNX execution provider
      with GPU support, is worth the conversion work. **The premise was half
      wrong:** only the 6-stem model forces `.cpu`. Kim Vocals is constructed
      with `.automatic`, which already appends the Core ML execution provider
      whenever ORT reports it available, so it is not CPU-only and the
      conversion work this item contemplates may already be unnecessary.
      What is still true is the two inferences per chunk, which are inherent to
      the model's denoising trick and cannot be removed without changing the
      output. Their *cost* is halved on the app's side: one accumulator now
      holds the running result instead of two full spectra and a zipped third.

### Acceptance criteria

- [ ] Vocals + Backing is measurably faster than Balanced 4-stem on the same
      song and device, or its label says otherwise. **Met by the second
      branch**, deliberately: the label still reads "Moderate" because nobody
      has timed the result.
- [ ] Peak memory during a vocal separation is measured, published in this plan,
      and gated on. **Gated on; not yet measured.** `SeparationRunMetrics` is
      the instrument.
- [~] Separated output is unchanged: the same song separated before and after
      is sample-identical, or the difference is explained. **Not sample-
      identical, and the difference is arithmetic rather than behavioural** —
      see the outcome. The bundled 4-stem path is covered end to end by
      `SeparationPipelineTests`, which separates a real file with the real model
      and checks the stems come out at the song's exact length.

### Outcome

**New files.** `PlanarAudioWindow.swift` holds `PlanarAudioWindowReader`, the
one thing all three separators now consume audio through.
`ResampledAudioStream` moved into `AudioResampler.swift` beside the whole-file
loader it replaced. `MDXSpectralTransformTests`, `PlanarAudioWindowTests`, and
`SeparationPipelineTests` are the coverage.

**The transform is real-to-complex now, and the tests pin the convention rather
than the code.** `vDSP_DFT_zrop` returns *twice* the mathematical transform with
the Nyquist bin packed into the imaginary DC slot, and its inverse returns
`nFFT` times the signal — conventions where a wrong factor of two still produces
plausible-sounding audio, which is exactly the kind of bug that ships. So
`MDXSpectralTransformTests` compares the forward transform against a direct DFT
computed in the test, rather than against the implementation's own output.

Everything around it went the same way:

- The explicit conjugate mirror — a loop per bin per frame, per channel — is
  simply gone. A real-to-complex inverse implies the symmetry, and band-limiting
  above `frequencyBins` is now "those slots were zeroed at allocation and are
  never written" instead of a bounds calculation.
- The overlap-add normalisation, a 2-million-iteration loop rebuilt on every
  inverse, depends only on the window and the hop. It is computed once, stored
  as a reciprocal, and applied with one `vDSP_vmul`.
- `reflected()` is called only for the eight frames of 256 that actually reach
  past the chunk's edge. The other 248 are one `vDSP_vmul` against the window.
- Every scratch buffer is allocated once per separator and reused for every
  chunk of every song.

**The mix is no longer held.** All three separators used to begin by decoding
the whole song into one planar float buffer — about 85 MB for four minutes,
170 MB at the moment of conversion because the undecoded source sat beside it —
and hold it for the entire run. `PlanarAudioWindowReader` pulls overlapping
windows out of a stream instead, so a ten-minute song costs the same as a
two-minute one. Each separator's window geometry stayed exactly what it was; the
reader takes a window, a hop, and a leading pad, and the MDX pair is the only
one that uses the pad, because its transform is centred.

**The chunk loop is driven by the file ending rather than by a frame count.**
That is the one behavioural change worth stating plainly: the old code computed
`total` from the fully converted buffer and derived a chunk count from it. A
stream has no length until it ends, and the estimate from `AVAudioFile.length`
is off by a frame or two after resampling — near enough for a progress bar,
not near enough to size the last chunk of audio. So the loop runs until the
stream is exhausted and sizes the final chunk from `deliveredFrames`, which is
measured. `SeparationPipelineTests` exists because a streaming loop that stops
one chunk early loses seconds off the end of every stem and still sounds like a
separation.

**A latent bug came out of it.** `AVAudioFile.read(into:)` does not report a
clean end of file: asked for frames past the last one it fails without setting
an error, which reaches Swift as an opaque `nilError`. The old code never met
this, because it made exactly one `convert` call into an exactly-sized buffer.
Reading in blocks meets it on the second call for any file shorter than the
block. The position, not the return value, is the reliable signal.

**Copies removed from the inference boundary.** MDX23C's Core ML output was
materialised in full (33.5 MB) and then each half copied out of it again — three
allocations to reach two inverse transforms. Both inverses now read the model's
own tensor in place. The input goes the same way: an `MLMultiArray` pointed at
the spectrum buffer, rather than a fresh 16.8 MB array per chunk. Kim Vocals
held four full spectra at once (positive, negated input, negative, and the
zipped average) and now holds one accumulator. `MLMultiArrayFloatReader` grew
the contiguity fast path that makes this possible — its `value(at:)` did four
divisions and modulos per element, which for the 4-stem model's 2.75 million
output values per chunk cost more than the copy it was avoiding. That one is a
speedup for the *default* model, which nothing in this phase set out to touch.

**Output is not sample-identical, and should not be expected to be.** A
real-to-complex transform sums in a different order than a complex-to-complex
one, `vDSP_vma` fuses a multiply and an add that used to round separately, and
the normalisation reciprocal is computed once and multiplied rather than divided
per sample. These are float reassociations at the 1e-6 level against signals in
the ±1 range. The round-trip test holds reconstruction to 1e-3 of the original
samples, which is a far tighter bound than any audible difference.

**The memory gates are provisional, and saying so is the point.** The plan asked
for "a real memory requirement", and the only measurement in existence is the
user's observation of over 2.5 GB in use during an MDX23C run. The app's own
share of that is now about 60 MB — one spectrum, the model's output, and the
windows around them — so effectively all of it is Core ML holding activations
for attention across 4,096 frequency bins. MDX23C is gated at 2 GB and Kim
Vocals at 1.5 GB: below the observed figure deliberately, so the gate blocks
devices that would be terminated part way through a long run without blocking
the ones where these models have been seen to work. They are placeholders for a
measurement, and `SeparationRunMetrics` — which logs elapsed time and the
headroom a run consumed — is there so that measurement takes one separation and
a glance at the log.

**Note the consequence for the simulator.** `os_proc_available_memory()` returns
zero there, so both vocal models now report as unavailable in every simulator,
exactly as `htdemucs6s` already did. That is pre-existing behaviour extended to
two more models, not a new problem, but it does mean the vocal paths cannot be
exercised without a device.

**Not verified on device.** Nothing in this phase has run on hardware. The
bundled 4-stem path is covered end to end in the simulator against the real
model, and the transform and window reader are covered by unit tests, but the
two models this phase is *about* cannot be reached in a simulator at all now.
Treat the measurement items above as the device pass.

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
- **Phase 13 was deliberately unscheduled, and has now been built.** It makes an
  existing feature faster and safer rather than adding one. Its implementation
  work is done; what remains is measurement on hardware — the before/after
  timing, the real memory peak behind the provisional gates, and the jetsam
  test — and that measurement is what stands between it and a public release.

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

### Fetch captions during the separation's extraction

Measured and viable; parked because it is a product decision, not a technical
one.

The separation already runs `yt-dlp` against the video to pick an audio format,
and YouTube returns the caption listing **in the same player response** that
extraction already fetches. Adding `--write-subs --write-auto-subs --sub-langs
en --sub-format vtt` to that existing call would therefore cost one ~4 KB
download and nothing else: measured at 2.83 s and 2.10 s for the call as it
stands today against 2.34 s and 2.62 s with captions added — inside run-to-run
noise.

**It cannot endanger the separation.** `YoutubeDL.process_info` writes the
`--print-to-file` metadata in `__forced_printings` *before* it calls
`_write_subtitles`, so a 429, a stalled socket, or a video with no English track
cannot cost the user their song. Confirmed against the bundled zipapp: with no
matching caption track, yt-dlp reports "There are no subtitles for the requested
languages", writes no `.vtt`, and `selection.json` is still complete.

What is *not* settled is whether it should happen at all. It fetches captions for
every separation, including for people who never open the Lyrics stage — one
more request to a host the app is already downloading from, but a request nobody
asked for, and a file written for a feature they may not use. If it is built, the
result should be parked as a *candidate* the Lyrics stage offers with its preview
intact, never as applied lyrics: "never present a guess as a fact" does not stop
applying because the words arrived early.

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
