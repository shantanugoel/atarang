# Practice Tools Implementation Plan

## Status

- [ ] Not started
- [~] In progress
- [x] Complete
- [!] Blocked or needs a decision

Update the checkboxes in this document as work progresses. Each phase should be
usable on its own; later phases should not be required to make earlier ones feel
complete.

## Product direction

Practice will be a focused workspace inside **Studio**, not a third top-level
tab or a separate audio system.

When a song is loaded, Studio will offer two views:

- **Mix** — choose what the user hears and configure recorded-take levels.
- **Practice** — control how the user rehearses the song.

Both views will share the same track, player, playhead, stem levels, recording
system, and persisted song state. Switching views must not interrupt playback.
The existing bottom transport remains visible in both views.

Technique practice without a song—such as a standalone tuner, metronome, or
timed routine—is outside the initial scope. It can become a separate utility
later if usage supports it.

## Guiding principles

- Make common actions usable while the user is holding an instrument.
- Prefer a few prominent controls over a dense collection of audio tools.
- Preserve synchronization across all stems under every playback transform.
- Save practice state per song so the next session resumes naturally.
- Keep musical analysis optional; the first useful release must not depend on
  beat, chord, or pitch detection.
- Explain stem limitations honestly. A guitar or piano practice target is only
  offered when that stem exists.
- Ensure VoiceOver, Dynamic Type, and minimum touch-target support in every
  phase.

## Phase 0 — Playback foundation

**Goal:** Make the shared audio engine safe for looping, variable speed, pitch
changes, and recording before adding new user-facing controls.

### Work

- [x] Introduce a single playback-state model for position, duration, rate,
      loop range, and playback generation.
- [x] Derive the playhead from audio render/sample time rather than only wall
      clock time.
- [x] Route every active stem through identical time/pitch processing.
- [~] Verify that stem synchronization is maintained after seeking, pausing,
      route changes, interruptions, and repeated playback.
- [x] Define loop-boundary scheduling that does not create gaps, double starts,
      or stale completion callbacks.
- [x] Define how transformed backing audio is captured by the existing
      recording pipeline.
- [x] Add unit coverage for range validation, rate-aware position calculation,
      loop transitions, and persisted state migration.
- [x] Add integration/manual test cases for headphones, speaker playback,
      Bluetooth routes, backgrounding, and screen lock.

### Acceptance criteria

- [~] All stems remain perceptibly synchronized for a complete song.
- [~] Seeking and restarting do not accumulate synchronization drift.
- [~] Playback position remains correct at supported speed settings.
- [~] Existing playback, mixing, recording, export, and History behavior does
      not regress.

## Phase 1 — Core song practice

**Goal:** Turn the existing stem mixer into a useful phrase-learning tool
without requiring automatic music analysis.

### 1. Studio workspace

- [x] Add a `Mix | Practice` selector when a track is loaded.
- [x] Preserve playback and scroll-independent player state when switching.
- [x] Keep the compact transport accessible in both views.
- [x] Rename **Recording Mix** to **Recorded Take Levels** or another label that
      clearly distinguishes it from the live stem mix.

### 2. A–B looping

- [x] Let the user set A and B at the current playhead.
- [x] Show A and B clearly on the timeline.
- [x] Let the user drag both boundaries.
- [x] Provide fine adjustments for each boundary.
- [x] Validate that `0 ≤ A < B ≤ duration` and enforce a useful minimum range.
- [x] Provide a one-tap way to enable, disable, and clear the loop.
- [x] Continue looping until explicitly stopped when not recording.

### 3. Essential transport controls

- [x] Add a prominent **Back 5 seconds** action.
- [x] Add pitch-preserving speed control.
- [x] Start with a conservative supported range, such as 50–100%.
- [x] Provide quick choices for common speeds such as 50%, 75%, 90%, and 100%.
- [x] Add a configurable count-in before song or loop playback.
- [x] Do not include the count-in in a saved recording.

### 4. Practice target and mix presets

- [x] Let the user select an available practice target: vocals, guitar, bass,
      drums, piano, or another available stem.
- [x] Add **Learn**: emphasize or solo the target.
- [x] Add **Guide**: keep a quieter target with the backing.
- [x] Add **Play Along**: mute the target.
- [x] Retain manual stem controls after applying a preset.
- [x] Replace or subsume the current vocal-only presets without losing their
      functionality.
- [x] Do not offer a dedicated target that the selected separation does not
      produce.

### 5. Per-song persistence

- [x] Save selected workspace, practice target, preset/mix, loop range, speed,
      count-in preference, and last position per song.
- [x] Restore saved state safely when a song is reopened from Library.
- [x] Provide a **Reset Practice Settings** action.
- [x] Version persisted settings so future schema changes can migrate or reset
      cleanly.

### Phase 1 acceptance criteria

- [x] A user can isolate a phrase, slow it down, hear a count-in, and repeat it
      without navigating away from the song.
- [x] A user can switch from learning a part to playing in place of it with one
      action.
- [x] Closing and reopening the song restores the useful practice context.
- [x] All Phase 1 controls are usable without precise timeline scrubbing.
- [x] Existing recordings created outside a loop behave as before.

## Phase 2 — Structured practice and performance

**Goal:** Support progressive rehearsal, different musical keys, and fast
comparison of practice takes.

### 1. Pitch and key

- [ ] Add pitch transpose independent of playback speed.
- [ ] Display the change in semitones.
- [ ] Offer octave and reset shortcuts where useful.
- [ ] Verify acceptable quality across vocals, bass, guitar, and full backing.
- [ ] Record the transformed backing exactly as the user hears it.

### 2. Manual metronome

- [ ] Add manual BPM entry and tap tempo.
- [ ] Add quarter-note, eighth-note, triplet, and sixteenth-note subdivisions.
- [ ] Add downbeat accent and click level controls.
- [ ] Let the user align the first click/downbeat manually with the song.
- [ ] Clearly label the metronome as manually aligned; do not imply automatic
      tempo tracking.
- [ ] Support metronome-only use within a loaded song before considering a
      standalone utility.

### 3. Repetition and tempo ramp

- [ ] Add an optional loop repetition target.
- [ ] Show completed and remaining repetitions.
- [ ] Optionally pause for a configurable duration between repetitions.
- [ ] Add tempo ramping after a chosen number of repetitions.
- [ ] Let the user set starting speed, increment, and target speed.
- [ ] Provide an immediate way to stop or hold the current speed.

### 4. Saved practice sections

- [ ] Save multiple named A–B regions per song.
- [ ] Provide useful default names and quick rename.
- [ ] Allow fast switching among regions such as Intro, Verse, Chorus, or Solo.
- [ ] Preserve independent speed or target settings only if user testing shows
      that this is understandable.

### 5. Loop recording and take comparison

- [ ] When recording with a loop active, initially support **Record one pass**.
- [ ] Play the count-in, record from A to B, and stop automatically at B.
- [ ] Lock loop, speed, pitch, and target settings during recording.
- [ ] Let the user quickly alternate between the reference and latest take.
- [ ] Keep the existing microphone/backing level editor and export behavior.
- [ ] Decide whether continuous multi-loop session recording belongs in a later
      release rather than silently producing repeated phrases.

### Phase 2 acceptance criteria

- [ ] Singers can move a song into a comfortable key without altering tempo.
- [ ] Instrumentalists can build a phrase from a slower speed to performance
      speed automatically.
- [ ] Users can save and return to multiple difficult sections of a song.
- [ ] A loop take starts and ends predictably and is immediately comparable.
- [ ] Manual click alignment stays stable for constant-tempo material.

## Phase 3 — Analysis-assisted practice

**Goal:** Add trustworthy musical intelligence after the manual workflow is
proven useful.

### 1. Beat and downbeat analysis

- [ ] Evaluate on-device beat/downbeat detection quality, latency, model size,
      and battery cost.
- [ ] Store an editable beat grid per song.
- [ ] Allow the user to correct BPM, downbeat, and alignment.
- [ ] Add beat-snapped seeking and loop boundaries.
- [ ] Synchronize the metronome to the beat grid.
- [ ] Support tempo maps before claiming reliable synchronization with
      non-constant-tempo recordings.

### 2. Pitch feedback

- [ ] Prototype low-latency pitch contour capture for voice and monophonic
      instruments.
- [ ] Prefer a visual contour and reference comparison over a simplistic score.
- [ ] Clearly indicate uncertain or unvoiced regions.
- [ ] Validate behavior with vibrato, slides, bends, octave errors, and
      background bleed.
- [ ] Keep raw performance recordings usable without analysis.

### 3. Optional transcription assistance

- [ ] Evaluate chord detection separately from note transcription.
- [ ] Show confidence or uncertainty rather than presenting guesses as facts.
- [ ] Let users correct analysis results.
- [ ] Consider octave shifting as a lightweight aid for bass and high-frequency
      transcription before building full note transcription.

### Phase 3 acceptance criteria

- [ ] Automatic features can be corrected or disabled.
- [ ] Beat-synchronized loops and click do not drift on supported songs.
- [ ] Feedback remains useful without penalizing expressive techniques.
- [ ] Analysis failure never blocks manual practice features.

## Future candidates

These should remain outside committed phases until there is evidence of demand:

- [ ] Standalone tuner.
- [ ] Standalone metronome and technique routines.
- [ ] Timed practice blocks and practice logs.
- [ ] Bluetooth pedal, headphone remote, keyboard, or voice control.
- [ ] Continuous multi-loop session recording and best-take extraction.
- [ ] Lyrics integration, subject to source availability and rights.
- [ ] Chord charts or score display.
- [ ] Shareable practice routines.

## Decisions to validate

- [ ] Confirm `Mix | Practice` terminology with a simple interactive prototype.
- [ ] Choose the minimum loop duration and boundary nudge increments.
- [ ] Choose the initial speed range based on audio quality testing.
- [ ] Decide whether count-in uses a fixed time or beat count before automatic
      beat analysis exists.
- [ ] Decide whether **Guide** uses a fixed target level or remembers the user's
      preferred guide level.
- [ ] Decide whether a saved practice section carries its own speed and mix.
- [ ] Decide how much practice state belongs in `UserDefaults` versus library
      metadata stored beside the track.
- [ ] Define expected behavior when a saved target is absent after a track is
      separated again with a different model.

## Release checklist for every phase

- [ ] Update user-facing help and accessibility labels.
- [ ] Verify compact and accessibility Dynamic Type layouts.
- [ ] Test VoiceOver focus order and control values.
- [ ] Test playback and recording with wired headphones, Bluetooth, and speaker.
- [ ] Test interruption, route-change, background, and screen-lock behavior.
- [ ] Test reopened tracks and older library metadata.
- [ ] Update `README.md` when the phase ships.
- [ ] Record known limitations and deferred work in this plan.
