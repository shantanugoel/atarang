# Atarang Improvements Plan

This plan prioritizes reliability and data safety first, then performance and
maintainability, followed by product and UI/UX improvements. Items are ordered
by recommended execution sequence rather than by implementation difficulty.

## Priority Definitions

- **P0 — Release confidence:** Complete before a broad public release.
- **P1 — Next engineering cycle:** High-value reliability, performance, and
  maintainability work.
- **P2 — Product improvement:** Valuable UX and capability improvements after
  the core is dependable and measurable.

## Baseline

At the time of the audit:

- The app and test bundle compiled successfully for iOS Simulator without
  standard compiler warnings.
- A strict-concurrency build succeeded with 19 warnings, including warnings
  that become errors under the Swift 6 language mode.
- The test suite contained 11 unit tests covering playback value logic and
  practice-settings persistence.
- Audio-route behavior, recording, exporting, separation, downloads, library
  recovery, and cancellation did not have automated integration coverage.
- Runtime audio testing was not performed because those flows need a
  representative physical-device matrix.

---

## Phase 1 — Eliminate Cross-Operation Races

### 1. Isolate separation operations

**Priority:** P0  
**ROI:** Very high  
**Mitigates:** Stale progress, overlapping work, cancelled operations changing
current state, and one task clearing another task's handle.

**Plan:**

- Give each separation request a stable operation ID or generation number.
- Keep all state updates conditional on the operation still being current.
- Replace detached work that cannot be cancelled with structured tasks or
  explicitly propagate cancellation to the underlying operation.
- Ensure cancellation stops download, extraction, model inference, and file
  generation as soon as safely possible.
- Make cancellation a distinct non-error terminal state.
- Prevent an older operation's cleanup from setting `isWorking` or the current
  task reference for a newer operation.

**Acceptance criteria:**

- Starting separation B immediately after cancelling A never allows A to alter
  B's progress, status, error, result, or task reference.
- Repeated cancel/restart cycles leave no partial library entry.
- UI cancellation becomes visible within a defined response target.
- Automated tests reproduce rapid cancel/restart and verify the final state.

### 2. Isolate recording export operations

**Priority:** P0  
**ROI:** Very high  
**Mitigates:** An old recording export appearing on a newly loaded song,
incorrect export indicators, and stale share URLs.

**Plan:**

- Track exports using a recording ID and generation token.
- Associate `isExporting`, export errors, and `shareURL` with the recording
  being exported rather than with the current player context.
- Decide explicitly whether export should continue when the user loads another
  song. If it continues, publish completion to the Library item only.
- Cancel or detach UI ownership when a track is unloaded.
- Make completed exports discoverable from Library even if Studio has changed.

**Acceptance criteria:**

- Loading another song during export never shows the previous song's share URL
  or export status in the new song.
- Every successful background export is available from its Library recording.
- Rapid record, stop, unload, and reload sequences are covered by tests.

---

## Phase 2 — Protect Recordings and Library Data

### 3. Make recording writes fail-fast and transactional

**Priority:** P0  
**ROI:** Very high  
**Mitigates:** Silent truncated takes, disk-full corruption, misleading success,
and incomplete microphone/backing pairs.

**Plan:**

- Capture microphone and backing writer failures as state rather than printing
  them and continuing.
- Stop recording safely when either writer fails and show an actionable reason.
- Write into a staging directory and commit the recording only after both
  streams close and validate successfully.
- Check that both files are readable and have a useful duration before
  committing metadata.
- Quarantine or remove failed staging directories.
- Consider a bounded writer queue or ring buffer so file I/O cannot block the
  real-time audio callback.

**Acceptance criteria:**

- Simulated microphone-write and backing-write failures end recording cleanly.
- No failed recording appears as a valid Library performance.
- A committed take always contains readable microphone and backing audio with
  consistent metadata.
- The user receives a clear recovery action after a recording failure.

### 4. Add capacity checks and a storage policy

**Priority:** P0  
**ROI:** Very high  
**Mitigates:** Mid-operation disk exhaustion, unexpectedly large app storage,
and excessive device or iCloud usage.

**Plan:**

- Estimate required space before downloading, separating, recording, and
  exporting, including staging overhead.
- Use system capacity APIs to block operations that cannot safely complete.
- Keep a reserve rather than consuming all reported free space.
- Exclude reproducible optional models and derived stems from backup.
- Decide whether downloaded originals are reproducible cache or user data and
  apply the corresponding backup policy.
- Preserve user-created performances according to an explicit backup policy.
- Show storage totals by Originals, Separations, Performances, Models, and
  temporary data.

**Acceptance criteria:**

- Operations fail before starting when capacity is insufficient.
- Error copy states how much additional space is needed.
- Reproducible assets do not inflate device backups.
- Storage totals match on-disk usage within an agreed tolerance.

### 5. Make all file installations and library commits atomic

**Priority:** P1  
**ROI:** High  
**Mitigates:** Broken assets after termination, partially compiled models,
orphaned stem folders, and missing metadata.

**Plan:**

- Download and generate into unique staging locations.
- Validate checksums, expected files, audio readability, and metadata before
  publishing.
- Commit using atomic replacement or a final directory rename.
- Never remove a known-good yt-dlp or model asset before a replacement is ready.
- Revalidate installed optional models using a manifest rather than existence
  alone.
- Remove abandoned staging directories during startup maintenance.

**Acceptance criteria:**

- Forced termination at every installation/commit boundary leaves either the
  previous valid asset or the new valid asset.
- A partial model directory is never reported as installed.
- A completed separation is either fully discoverable or fully absent.

### 6. Add library integrity checking and recovery

**Priority:** P1  
**ROI:** High  
**Mitigates:** User content silently disappearing when metadata is damaged or a
file is missing.

**Plan:**

- Distinguish valid, recoverable, incomplete, and corrupt library folders.
- Reconstruct safe metadata where IDs, filenames, duration, or dates can be
  derived reliably.
- Quarantine unrecoverable entries instead of silently skipping them.
- Provide a storage diagnostics view with repair, export, and delete options.
- Record structured diagnostics without exposing private media metadata.

**Acceptance criteria:**

- Corrupt test fixtures produce explicit recoverable/unrecoverable results.
- Recoverable audio is visible again after repair.
- No corrupted item disappears without a diagnostic record.

---

## Phase 3 — Establish Automated Release Confidence

### 7. Build integration tests around critical workflows

**Priority:** P0  
**ROI:** Very high  
**Mitigates:** Regressions in the app's most failure-prone behavior.

**Test areas, in recommended order:**

1. Separation generation and cancellation races.
2. Export generation and stale-result handling.
3. Recording transaction commit and writer failures.
4. Library discovery, corruption, migration, and recovery.
5. Model download validation and partial installation.
6. Recording export and mix-level correctness using fixture audio.
7. YouTube URL normalization and source identity.
8. Low-storage and network-error state mapping.
9. App relaunch during each durable operation.

**Acceptance criteria:**

- Critical business logic is injectable and testable without live network or
  physical audio hardware.
- Every fixed race or data-loss bug receives a regression test.
- Tests use isolated temporary directories and `UserDefaults` suites.

### 8. Add CI release gates

**Priority:** P0  
**ROI:** Very high  
**Mitigates:** Broken builds, untested migrations, concurrency regressions, and
device-family layout regressions.

**Plan:**

- Build and run unit/integration tests on every change.
- Add strict-concurrency compilation as a non-blocking gate initially, then
  promote it to blocking.
- Add launch and core navigation UI tests for the oldest supported iOS and the
  current iOS release.
- Add representative iPhone and iPad screenshot tests at standard and
  accessibility Dynamic Type sizes.
- Archive test artifacts and diagnostics for failed runs.

**Acceptance criteria:**

- Pull requests cannot merge with a failed build or critical test.
- The CI matrix covers iOS 17 and the latest supported iOS SDK/runtime where
  infrastructure permits.
- Strict-concurrency warnings have an explicit ratchet and cannot increase.

### 9. Create a physical-device audio reliability matrix

**Priority:** P0  
**ROI:** High  
**Mitigates:** Simulator blind spots in microphone, Bluetooth, interruptions,
background audio, and thermal behavior.

**Required scenarios:**

- Built-in speaker and microphone.
- Wired or USB audio when available.
- AirPods/Bluetooth playback and HFP recording transition.
- Headphones disconnected during playback and recording.
- Phone call, Siri, alarm, and other audio-session interruption.
- App backgrounding and device lock during recording.
- Route changes immediately before and after recording starts.
- Repeated recordings, playback restarts, and export while navigating.
- Long recording and long separation under thermal and memory pressure.

**Acceptance criteria:**

- Results are recorded by device, OS version, route, and build configuration.
- Every stopped recording reports whether it was saved and why it ended.
- Release-blocking scenarios have repeatable pass/fail criteria.

### 10. Add a YouTube extraction canary and dependency review

**Priority:** P1  
**ROI:** Very high  
**Mitigates:** The primary import flow suddenly failing after upstream changes,
plus unnoticed dependency security or compatibility risk.

**Plan:**

- Run a scheduled metadata and small-audio extraction against controlled,
  permitted test content.
- Alert on metadata, format-selection, download, or checksum failures.
- Document the yt-dlp update and checksum process.
- Regularly review the older Python, FFmpeg, and YouTube wrapper dependencies.
- Track upstream versions, licenses, vulnerabilities, and iOS compatibility.
- Test dependency updates in an isolated branch before changing production pins.

**Acceptance criteria:**

- Upstream breakage is detected before users report it.
- Updating the bundled extractor is documented and reproducible.
- Dependency review has a named cadence and owner.

---

## Phase 4 — Improve Runtime Performance and Concurrency Safety

### 11. Move Library scanning and indexing off the main actor

**Priority:** P1  
**ROI:** Very high  
**Mitigates:** Launch stalls, Library scrolling/search delays, and worsening
performance as storage grows.

**Plan:**

- Perform directory traversal, audio-duration reads, and byte counting on a
  dedicated actor or background service.
- Publish an immutable Library snapshot to the UI.
- Maintain a lightweight persistent index updated transactionally as items are
  added, edited, or deleted.
- Reconcile the index with disk incrementally rather than rescanning everything.
- Coalesce duplicate refresh notifications.
- Move existing-separation lookup out of `ContentView` and avoid full scans
  while typing.

**Acceptance criteria:**

- Library refresh does not block the main thread.
- Launch and Library-open timings remain stable with a large fixture library.
- A single data mutation produces at most one UI snapshot refresh.

### 12. Narrow SwiftUI observation and rendering scope

**Priority:** P1  
**ROI:** High  
**Mitigates:** Whole-screen invalidation from playback timers, meters, sliders,
and unrelated player state.

**Plan:**

- Split playback transport, recording meter, mixer, practice settings, and
  export state into narrower observable surfaces.
- Pass stable, derived values into leaf views.
- Keep high-frequency position and meter updates local to their small subtrees.
- Avoid using a broad root `ObservableObject` as the dependency for every
  Studio component.
- Profile SwiftUI updates before and after the refactor on device.

**Acceptance criteria:**

- Playback position and microphone meter updates do not recompute the import,
  practice, or Library surfaces.
- SwiftUI Instruments shows materially narrower invalidation.
- CPU and energy measurements improve or remain neutral.

### 13. Resolve strict-concurrency warnings and migrate toward Swift 6

**Priority:** P1  
**ROI:** High  
**Mitigates:** Future compiler failures and real races around audio buffers,
converter callbacks, and shared package state.

**Plan:**

- Remove concurrently mutated captured variables from converter input blocks.
- Encapsulate non-Sendable AVFoundation objects behind actor or queue ownership.
- Audit every `@unchecked Sendable` conformance and document the synchronization
  invariant or remove the conformance.
- Isolate mutable state exposed by the YouTube dependency.
- Separate warnings generated by app code from generated Core ML code.
- Enable strict concurrency in project settings once app-owned warnings are
  resolved, then evaluate Swift 6 language mode.

**Acceptance criteria:**

- App-owned strict-concurrency warnings are zero.
- Every remaining generated-code warning is documented with an upstream or
  containment strategy.
- Swift 6 compilation is tested in CI before becoming the project default.

### 14. Refactor large views into feature components

**Priority:** P1  
**ROI:** High  
**Mitigates:** Accidental coupling, difficult reviews, slow iteration, and poor
test isolation.

**Recommended boundaries:**

- Studio shell and routing.
- Song import and model choice.
- Separation progress.
- Mixer and stem rows.
- Practice timeline and loop editor.
- Structured practice and metronome.
- Recording controls and transport.
- Library shell, rows, selection, deletion, and separation sheet.

**Acceptance criteria:**

- Feature views receive only the state and actions they use.
- Navigation and presentation state has a clear owner.
- Components have previews for loading, empty, error, active, recording, and
  accessibility states.
- The refactor produces no intentional UX change.

---

## Phase 5 — Make Reliability Observable and Actionable

### 15. Add MetricKit, signposts, and structured operation logging

**Priority:** P1  
**ROI:** High  
**Mitigates:** Unexplained hangs, memory termination, slow inference, audio
startup failures, and support cases without evidence.

**Plan:**

- Add signpost intervals for extraction, audio download, model download,
  inference, library refresh, audio startup, recording finalization, and export.
- Attach a privacy-safe operation ID to related events.
- Collect MetricKit crash, hang, CPU, memory, and disk-write diagnostics.
- Provide a user-controlled diagnostics export that excludes URLs, song titles,
  and recorded media unless explicitly included.
- Define baseline performance budgets for critical operations.

**Acceptance criteria:**

- A field failure can be correlated across its operation stages.
- Metrics do not contain private song or recording data by default.
- Performance regressions can be compared against a documented baseline.

### 16. Explain interruption and recovery states in the UI

**Priority:** P1  
**ROI:** Very high  
**Mitigates:** Users believing a take vanished or the app stopped arbitrarily.

**Plan:**

- Record the reason playback or recording ended.
- Show persistent banners for route disconnect, interruption, disk failure, or
  audio engine restart.
- State whether a partial or complete take was saved.
- Offer relevant actions such as Play Take, Open Library, Retry, or Audio Help.
- Avoid presenting expected cancellation as a generic error alert.

**Acceptance criteria:**

- Every non-user-initiated recording stop has user-visible explanatory state.
- Returning from a call or route change clearly shows the recording outcome.
- VoiceOver announces important interruption and completion states.

---

## Phase 6 — Improve Core Product UX

### 17. Simplify Practice with progressive disclosure

**Priority:** P2  
**ROI:** High  
**Mitigates:** Cognitive overload, long scrolling, and advanced controls hiding
the primary practice loop.

**Plan:**

- Keep timeline, back five seconds, speed, A-B loop, and record immediately
  available.
- Group pitch, saved sections, repetitions, tempo ramp, metronome, target mix,
  and count-in into clear expandable tool sections.
- Remember expanded sections per user or song where appropriate.
- Show disabled-state explanations close to dependent controls.
- Consider a compact “practice session” summary that shows active loop, speed,
  key, target, and repetition goal.

**Acceptance criteria:**

- A first-time user can create and repeat an A-B loop without traversing
  advanced settings.
- Existing capabilities remain reachable within one additional interaction.
- Dynamic Type and VoiceOver reading order remain coherent.

### 18. Present separation choices by user outcome

**Priority:** P2  
**ROI:** Very high  
**Mitigates:** Choice paralysis and users selecting an unnecessarily slow or
large model.

**Plan:**

- Lead with outcome-oriented names such as Balanced 4-stem, Detailed 6-stem, and
  Vocals + Backing.
- Keep the technical model name as secondary information.
- Show expected quality goal, speed class, stem list, device compatibility,
  download size, and installed status.
- Recommend a default based on the user's stated or inferred task without
  preventing manual selection.
- Explain why a model is unavailable and what alternative to choose.

**Acceptance criteria:**

- Users can distinguish the choices without knowing model architecture names.
- Download and performance consequences are visible before confirmation.
- Technical model identity remains discoverable for advanced users.

### 19. Turn Settings into a functional support and control surface

**Priority:** P2  
**ROI:** Very high  
**Mitigates:** A misleading Settings tab and avoidable support burden.

**Recommended sections:**

- Storage usage and cleanup.
- Installed optional models.
- Default separation choice.
- Recording defaults and audio troubleshooting.
- Privacy and backup behavior.
- Diagnostics export.
- About, version, acknowledgements, and project link.

If no actual preferences are planned, rename the tab and navigation title to
**About** instead.

**Acceptance criteria:**

- The tab name accurately describes its content.
- Users can inspect and manage the app's largest storage consumers.
- Common audio and download recovery steps are available in-app.

### 20. Add local audio import

**Priority:** P2  
**ROI:** High  
**Mitigates:** Total dependence on YouTube extraction and inability to process
audio the user already owns.

**Plan:**

- Support Files/document picker import for compatible audio.
- Accept audio files from the system share sheet where practical.
- Copy imported content through the same transactional Original pipeline.
- Clearly disclose supported formats, local processing, and storage impact.
- Preserve source filenames safely while allowing editable display titles.

**Acceptance criteria:**

- A supported local file can be imported, separated, reused, and deleted without
  any network request.
- Unsupported and DRM-protected content produces actionable error messaging.
- Local and YouTube originals behave consistently in Library.

### 21. Formalize adaptive and accessibility QA

**Priority:** P2  
**ROI:** Medium-high  
**Mitigates:** Clipped controls, awkward iPad layouts, inaccessible state, and
regressions in the app's existing Dynamic Type support.

**Plan:**

- Test all screens in portrait and landscape on small and large iPhones.
- Test compact and regular iPad layouts; consider a split view or persistent
  inspector where it improves Library and mixer workflows.
- Cover every accessibility Dynamic Type size.
- Audit VoiceOver labels, values, hints, rotor order, modal focus, and
  announcements.
- Verify contrast, Reduce Motion, Differentiate Without Color, and button target
  sizes.
- Add screenshot/UI tests for representative states.

**Acceptance criteria:**

- Core tasks are completable at the largest accessibility text size.
- No essential meaning is conveyed by color alone.
- iPad makes productive use of available space without stretching phone layouts.
- Accessibility and layout tests run in CI.

---

## Recommended Delivery Milestones

### Milestone A — Safe operations

Complete items 1–7. The goal is to prevent stale work, silent recording damage,
and incomplete durable state, with regression tests for each risk.

### Milestone B — Release confidence

Complete items 8–10. The goal is a repeatable CI/device validation process and
early warning when the external YouTube path breaks.

### Milestone C — Scalable architecture

Complete items 11–14. The goal is stable performance with a growing library,
narrow SwiftUI updates, strict concurrency readiness, and maintainable feature
boundaries.

### Milestone D — Field reliability

Complete items 15–16. The goal is measurable production behavior and clear
recovery communication.

### Milestone E — Product refinement

Complete items 17–21. The goal is to make the existing feature depth easier to
understand, reduce external dependency, and improve settings, iPad, and
accessibility experiences.

## Definition of Done for Every Item

- The behavior has automated coverage where technically practical.
- Expected cancellation is not reported as an error.
- Durable changes are atomic or recoverable.
- User-facing failure states explain what happened and what to do next.
- Accessibility behavior is verified for any changed interaction.
- Relevant performance or reliability metrics are captured before and after.
- No new strict-concurrency warnings are introduced.
- Documentation is updated when storage, privacy, backup, or dependency behavior
  changes.
