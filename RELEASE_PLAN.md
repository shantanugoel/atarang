# Atarang App Store Release Plan

Last reviewed: 2026-07-29

## Objective

Ship Atarang through Apple's App Store while keeping the existing YouTube-based
workflow available only in a separate GitHub/sideload build.

The App Store artifact must be a genuinely separate product flavor. It must not
contain hidden or disabled YouTube behavior, downloader code, downloader
resources, YouTube-specific metadata, or dormant entry points.

This plan assumes that the Apple Developer Program membership is already active.

## Ownership

- **Codex** — work that can normally be implemented, tested, documented, or
  prepared in the repository and local Xcode environment.
- **User** — decisions, attestations, credentials, contracts, or App Store
  Connect actions that cannot safely be inferred or completed without the
  account holder.
- **Joint** — Codex prepares the evidence or draft; the user confirms or performs
  the final external action.

The intent is for Codex to complete everything marked **Codex** and prepare
nearly finished material for every **Joint** item.

## Non-negotiable release rules

1. The App Store build will import audio files explicitly selected by the user.
   It will not fetch media from YouTube or another third-party media service.
2. The GitHub build may retain the current YouTube workflow, but it uses a
   different target, scheme, product bundle identifier, and release artifact.
3. YouTube functionality will be excluded by target membership and dependency
   linkage, not hidden with a runtime flag or remote configuration.
4. Only the App Store scheme may be archived for App Store distribution or
   uploaded to TestFlight.
5. Store metadata, screenshots, privacy disclosures, support pages, and review
   notes must describe the Store build exactly.
6. Every release must pass an automated scan of the exported App Store `.ipa`
   for prohibited YouTube/downloader traces.
7. A GitHub release does not eliminate YouTube terms-of-service or enforcement
   risk. It is a separate distribution choice, not a compliance workaround.

## Default product decisions

These defaults let Codex proceed without repeatedly blocking on product choices.
They can be changed before implementation:

- App Store target: `AtarangAppStore`
- App Store scheme: `Atarang App Store`
- App Store display name: `Atarang`
- GitHub target: `AtarangGitHub`
- GitHub scheme: `Atarang GitHub`
- GitHub display name: `Atarang GitHub`
- Minimum iOS version: keep iOS 17 unless device testing identifies a reason to
  raise it
- App Store input: Files-based import of locally available audio
- Store pricing: undecided; does not block engineering
- Store territories: undecided; does not block engineering

The production identifiers must be decided before Phase 1. The current
development/sideload build uses `com.shantanugoel.atarang.Atarang`; moving that
identifier to the Store target would strand existing GitHub-build containers.
The recommended default is therefore:

- keep `com.shantanugoel.atarang.Atarang` on the GitHub target; and
- register a new permanent bundle identifier for the Store target.

If the current identifier is instead reserved for the Store, Codex must first
ship an export-capable GitHub build on the old identifier and add a matching
import path to the new GitHub identifier.

Two other decisions must be made before Phase 1:

- **User:** Choose iPhone-only for v1 or universal iPhone/iPad. The current
  target is universal; iPhone-only reduces layout and screenshot scope.
- **User:** Confirm whether the bundled HTDemucs model remains bundled for v1.
  Bundling is the default because it provides an offline and reproducible review
  path; Codex will report the actual archive/download/installed-size impact
  before the choice is finalized.

## Phase 0 — Freeze a reproducible baseline

### Account-holder and product unblocks

- [ ] **User:** Choose the permanent Store/GitHub bundle-identifier assignment
  described above.
- [ ] **User:** Choose iPhone-only or universal iPhone/iPad support for v1.
- [ ] **User:** Confirm all current Apple agreements are accepted.
- [ ] **User:** Confirm DSA trader status if distributing in the EU.
- [ ] **User:** Complete tax/banking setup early if the app will be paid.
- [ ] **Joint:** Create or verify the production App ID and App Store Connect app
  record as soon as the Store identifier is chosen.
- [ ] **User:** Optionally create a narrowly scoped App Store Connect API key and
  keep it outside the repository if later upload/metadata automation is desired.
  Credentials are not a prerequisite for repository engineering.

### Repository and build baseline

- [ ] **Codex:** Record the current branch, commit, working-tree state, Xcode
  version, SDK version, Swift package resolution, schemes, build settings, and
  deployment target.
- [ ] **Codex:** Build the current app and run the existing test suite before
  refactoring.
- [ ] **Codex:** Record known pre-existing warnings and failures separately from
  regressions.
- [ ] **Codex:** Produce a baseline app-bundle inventory, including executable,
  resources, embedded frameworks, Swift package products, entitlements, Info
  plist, App Intent metadata, and app size.
- [ ] **Codex:** Verify Git LFS is installed and resolved, `git lfs status` is
  clean, and the HTDemucs `weight.bin` is real model data rather than an LFS
  pointer. Record and later enforce its expected checksum.
- [ ] **Codex:** Report the current compiled HTDemucs model size, exported archive
  size, App Store download-size estimate when available, and installed size.
- [ ] **Codex:** Add a release-work tracking section to this document as work is
  completed, including commit IDs and verification evidence.

### Model rights gate

- [ ] **Codex:** For the bundled HTDemucs Core ML FP16 model and each optional
  model (HTDemucs 6-stem ONNX, MDX23C InstVoc HQ, and Kim Vocal 2), capture:
  - the architecture/code license;
  - the model-weights license as a separate artifact;
  - the conversion/repackaging license and chain of provenance;
  - attribution, redistribution, commercial-use, and hosting requirements.
- [ ] **Codex:** Treat any model whose weights or conversion rights cannot be
  established as excluded from the Store v1 feature set.
- [ ] **User:** Make the final per-model `ship`, `drop`, or `replace` decision
  before Store model choices, notices, screenshots, and metadata are finalized.

### Policy baseline

- [ ] **Codex:** Recheck the current Apple App Review Guidelines, submission SDK
  requirements, privacy-manifest rules, and App Store Connect requirements
  immediately before implementation and again immediately before submission.
- [ ] **Codex:** Save links and the review date in the release evidence.
- [ ] **Codex:** Treat Apple guideline changes as release blockers until their
  impact is assessed.

Exit criteria:

- The unmodified project has a known build/test status.
- Current bundle contents and policy assumptions are documented.
- Product identity/device-family choices are recorded.
- Every Store v1 model has a documented rights disposition.

## First-submission critical path

The first submission still uses the two-target architecture; maintaining a
separate long-lived YouTube branch would reduce the initial refactor but create
unsafe source divergence immediately afterward.

Keep the first submission scoped to:

1. physical shared/Store/GitHub source ownership and committed schemes;
2. source-neutral separation plus Files and bundled-demo ingestion;
3. only models whose rights are established before metadata work;
4. per-flavor plists, entitlements, privacy manifests, notices, and docs;
5. mechanical Store archive identity/dependency/trace gates;
6. physical-device verification and internal TestFlight;
7. screenshots and required Store metadata; and
8. submission of the exact scanned artifact.

Defer external TestFlight, App Preview video, optional Store models with
unresolved rights, GitHub binary publication, and release-pipeline refinements
that do not strengthen the Store artifact gate.

## Phase 1 — Split the product into explicit build flavors

### Target architecture

- [ ] **Codex:** Replace the current single synchronized `Atarang/` source folder
  with physically owned source roots:
  - `AtarangCore/` for shared separation, practice, recording, analysis, storage,
    and source-neutral UI, attached to both app targets;
  - `AtarangAppStore/` for the Store entry point, local importer, Store-only
    composition, plist, notices, privacy resources, and assets;
  - `AtarangGitHub/` for the GitHub entry point, YouTube adapters, App Intent,
    plist, notices, `yt-dlp`, and GitHub-only assets.
- [ ] **Codex:** Do not use
  `PBXFileSystemSynchronizedBuildFileExceptionSet` deny lists to keep GitHub
  files out of the Store target. The Store must fail closed: a new file placed
  in `AtarangGitHub/` is never a Store target member by default.
- [ ] **Codex:** Create thin `AtarangAppStore` and `AtarangGitHub` app targets
  with separate `@main` entry points.
- [ ] **Codex:** Commit shared `Atarang App Store` and `Atarang GitHub` schemes
  under `Atarang.xcodeproj/xcshareddata/xcschemes/`.
- [ ] **Codex:** Verify `xcodebuild -list` reports both schemes from a disposable
  clean checkout with no `xcuserdata`.
- [ ] **Codex:** Create unambiguous Release configurations and archive actions
  for each flavor.
- [ ] **Codex:** Drive flavor-varying identity through checked-in `.xcconfig`
  files, including `PRODUCT_BUNDLE_IDENTIFIER`, `PRODUCT_NAME`,
  `INFOPLIST_FILE`, `CODE_SIGN_ENTITLEMENTS`, `MARKETING_VERSION`,
  `CURRENT_PROJECT_VERSION`, and an `ATARANG_FLAVOR` setting.
- [ ] **Codex:** Split `Atarang-Info.plist` and entitlements into explicit
  per-flavor files. Set `CFBundleDisplayName` from a build setting.
- [ ] **Codex:** The Store plist must contain no `CFBundleURLTypes`; the current
  `atarang://` handler is YouTube-only. Preserve document-type declarations only
  when the Store has a tested non-YouTube handler.
- [ ] **Codex:** Replace hardcoded logger subsystems with the active bundle
  identifier.
- [ ] **Codex:** Make the GitHub flavor mechanically distinguishable:
  `CFBundleDisplayName` is `Atarang GitHub`, its icon has a distinct overlay, and
  tests assert its name, bundle ID, and flavor setting.
- [ ] **Codex:** Ensure tests can run against shared code and add
  flavor-specific test targets where needed.

### Dependency isolation

- [ ] **Codex:** Move the `YoutubeDL` package product dependency from the common
  app target to the GitHub target or a GitHub-only feature module.
- [ ] **Codex:** Ensure Python, FFmpeg components pulled in by `YoutubeDL`, and
  the bundled `yt-dlp` resource are linked or copied only by the GitHub target.
- [ ] **Codex:** Move all GitHub-only code and resources into
  `AtarangGitHub/`; do not depend on individual file membership exclusions.
- [ ] **Codex:** Ensure the Store target does not expose GitHub-only symbols to
  SwiftUI previews, tests, App Intents, or generated metadata.
- [ ] **Codex:** Create `Scripts/release-gate.sh` and `Scripts/scan-ipa.sh`.
  Implement dependency/resource checks as post-build/release checks against the
  built product and exported `.ipa`, not as sandboxed Xcode run-script phases.
  Do not disable `ENABLE_USER_SCRIPT_SANDBOXING`.

Implementation preference:

- Use target/module boundaries for feature exclusion.
- Compilation conditions may select generic UI composition, but they must not
  be the only mechanism keeping downloader code out of the Store artifact.
- Do not use a server flag, secret gesture, custom URL, environment variable, or
  date-based switch to expose GitHub functionality in the Store build.

Exit criteria:

- Both schemes compile.
- In a disposable clean checkout, the Store target builds while the GitHub-only
  source/resource folder is made unavailable.
- The Store target owns no synchronized-folder exception set used to exclude
  GitHub files.
- The Store target has no dependency path to `YoutubeDL` or `yt-dlp`.
- Processed Store identity, plist, entitlements, and App Intent inventory match
  committed expected values.

## Phase 2 — Introduce source-neutral audio ingestion

The current import and separation flow assumes a YouTube URL. The shared
pipeline must instead accept an already-local original, while source-specific
adapters acquire that original.

### Shared ingestion model

- [ ] **Codex:** Define a source-neutral ingestion result containing the staged
  local audio URL, display title, content identity, optional user-provided
  metadata, and cleanup requirements.
- [ ] **Codex:** Define local content identity as
  `local:sha256:<full-file-digest>`, calculated while staging/copying the audio
  and stored in `sourceKey`. Do not persist a Files/file-provider URL as identity;
  `sourceURL` is `nil` for local imports.
- [ ] **Codex:** Move shared deduplication to
  `LibraryIndex.separation(forSourceKey:)`. The GitHub adapter alone converts a
  YouTube URL to a `youtube:` source key.
- [ ] **Codex:** Add schema versions and legacy-defaulting decoders to
  `OriginalMetadata` and `TrackMetadata`. Existing `sourceURL` and `sourceKey`
  fields remain decodable; new required fields must be defaulted or optional.
- [ ] **Codex:** Refactor the separation pipeline so its core operation starts
  from a local audio file.
- [ ] **Codex:** Keep download/re-download behavior outside the shared
  separation core.
- [ ] **Codex:** Remove assumptions that every library original has a remote
  source URL or can be downloaded again.
- [ ] **Codex:** Preserve backward compatibility for existing GitHub libraries
  containing YouTube source metadata.

### Originals durability

- [ ] **Codex:** Treat Store-imported originals as user data, not reproducible
  cache. Do not set `isExcludedFromBackup` on imported original audio.
- [ ] **Codex:** Keep separated stems and optional models backup-excluded when
  they are reproducible from a retained original or pinned download.
- [ ] **Codex:** Update storage estimates, eviction rules, backup settings,
  library recovery, diagnostics, documentation, and user-facing copy to reflect
  the difference between durable imported originals and reproducible artifacts.
- [ ] **Codex:** Add tests proving imported originals are not backup-excluded,
  reproducible stems/models are excluded, and local originals are never evicted
  as remotely redownloadable cache.

### App Store Files importer

- [ ] **Codex:** Add a SwiftUI Files importer using system audio content types.
- [ ] **Codex:** Validate the selected file before starting a separation.
- [ ] **Codex:** Handle security-scoped access correctly and copy the original
  into Atarang-managed staging before access ends.
- [ ] **Codex:** Use the existing atomic staging/commit and capacity checks.
- [ ] **Codex:** Support at least the audio formats that pass real-device
  decoding tests; present a clear error for unsupported or protected files.
- [ ] **Codex:** Derive a sensible title from metadata or filename and allow it
  to be edited.
- [ ] **Codex:** Avoid claiming that Atarang has rights to the selected file;
  explain that the user should import audio they are allowed to use.
- [ ] **Codex:** Make local import accessible with VoiceOver, Dynamic Type,
  keyboard navigation where applicable, and useful progress/cancellation UI.
- [ ] **Codex:** Add unit and integration coverage for successful import,
  cancellation, insufficient storage, invalid audio, duplicate import, file
  provider delays, and loss of security-scoped access. Verify that the same file
  imported from different Files locations deduplicates and different files with
  the same filename do not collide.
- [ ] **Codex:** Add a bundled approximately 30-second demo track and a
  “Try a sample track” action on the Store empty state. Route it through the same
  staging and separation boundary as a Files import.
- [ ] **User:** Supply a self-recorded demo clip or approve a verified
  public-domain/CC0 clip. A self-recording is preferred.

### GitHub adapter

- [ ] **Codex:** Move the existing YouTube validation, metadata extraction,
  download, captions, App Intent, and re-download behavior behind the
  GitHub-only feature boundary.
- [ ] **Codex:** Adapt the GitHub downloader output to the same source-neutral
  local ingestion result.
- [ ] **Codex:** Keep current GitHub behavior and tests working unless a change
  is required by the shared architecture.

Exit criteria:

- A user can install the Store build, import an audio file from Files, separate
  it, and use the complete practice workflow without the GitHub module.
- A reviewer can exercise the same core path from a clean device using the
  bundled demo track without an account or external file.
- The GitHub build still accepts its existing links and reaches the same shared
  separation core.
- Legacy library metadata decodes in tests, and local-import backup/deduplication
  rules pass their objective assertions.

## Phase 3 — Remove all YouTube traces from the Store product

### Code and UI inventory

- [ ] **Codex:** Move `BundledYTDLP.swift`, `YouTubeSource.swift`,
  `ImportYouTubeIntent.swift`, and the YouTube-specific paths currently inside
  `SeparationModel.swift`, `ContentView.swift`, `ImportView.swift`,
  `LyricsLookup.swift`, `LibraryIndex.swift`, `SettingsStorage.swift`, and
  `StorageCapacity.swift` into the physically GitHub-only source root.
- [ ] **Codex:** Split YouTube caption lookup from generic lyrics lookup.
- [ ] **Codex:** Remove Store references from import UI, content routing,
  library lookup, history actions, lyrics screens, settings, privacy screens,
  diagnostics, logger categories, errors, accessibility labels, and empty
  states.
- [ ] **Codex:** Remove YouTube-specific App Intents and generated shortcut
  phrases from the Store build.
- [ ] **Codex:** Remove downloader checksums, versions, source hostnames, and
  extractor arguments from Store resources and compiled strings.
- [ ] **Codex:** Ensure test fixtures and previews are not accidentally bundled
  into the Store app.
- [ ] **Codex:** Use Store-specific third-party notices that omit components not
  shipped by the Store target.

### Store-facing links and documentation

- [ ] **Codex:** Replace the Store build's “View Project on GitHub” link with a
  Store-specific support/project page, or remove it.
- [ ] **Codex:** Create Store-specific support, privacy, and product pages that
  accurately describe local audio import.
- [ ] **Codex:** Keep the repository README explicit that YouTube functionality
  belongs only to the GitHub/sideload build.
- [ ] **Codex:** Ensure Store screenshots and walkthrough media do not show a
  YouTube URL, YouTube name/logo, downloader, or GitHub-only controls.
- [ ] **Codex:** Rewrite `docs/index.html`, its title/meta/Open Graph/hero/feature
  copy, and `docs/images/import.png` to describe the Store's local import flow.
  Put GitHub-flavor documentation on a clearly separate page that is not used as
  the App Store support or marketing URL.
- [ ] **Codex:** Ensure any public comparison between builds is factual and does
  not tell App Store customers that a hidden Store feature exists.

### Automated archive scan

- [ ] **Codex:** Add a repository script that exports/unpacks the App Store
  `.ipa` and scans:
  - filenames and directories;
  - executable and framework strings;
  - symbol tables where present;
  - Info plists and entitlements;
  - asset catalogs and ordinary resources;
  - App Intent/shortcut metadata;
  - embedded frameworks, libraries, plug-ins, and package resources.
- [ ] **Codex:** Fail the Store release when any case-insensitive match is found
  for at least:
  - `youtube`
  - `youtu.be`
  - `youtubedl`
  - `yt-dlp`
  - `yt_dlp`
  - `ytdlp`
  - `googlevideo`
  - `innertube`
  - `python`
  - `libpython`
  - `PythonSupport`
  - `ffmpeg`
  - `libav`
  - `kewlbear`
- [ ] **Codex:** Add structural assertions independent of string matching:
  - processed `CFBundleIdentifier` equals the permanent Store identifier;
  - processed Info plist contains no `CFBundleURLTypes`;
  - the app contains no `yt-dlp` file, Python support bundle/interpreter, FFmpeg
    or libav binary, or `YoutubeDL` package product;
  - App Intent metadata parses to a committed expected-action inventory and no
    action identifier/title/parameter matches the forbidden list;
  - the Store executable has no `UIPasteboard` reference while the paste
    affordance remains GitHub-only.
- [ ] **Codex:** Permit no unexplained allowlist entries. If a false positive
  exists, document the exact artifact and why it cannot represent functionality
  or marketing.
- [ ] **Codex:** Store the scan report and bundle inventory as release evidence.

Exit criteria:

- The exported Store `.ipa`, not merely the source target, passes the trace
  scan.
- The Store's processed identity/plist, embedded dependency inventory, and App
  Intent action set exactly match committed expected fixtures.
- Store support/marketing URLs resolve successfully and describe only Store
  functionality.

## Phase 4 — Privacy, security, entitlements, and licensing

### Privacy manifest and disclosures

- [ ] **Codex:** Generate Xcode's privacy report for the Store archive.
- [ ] **Codex:** Inventory required-reason API use in app and dependency code.
  Current known categories and candidate reasons, to be verified against the
  implementation and current Apple documentation, are:
  - UserDefaults (`CA92.1`) for app-only preferences;
  - file timestamps (`C617.1`) for files in the app container and `3B52.1` only
    if timestamps of document-picker-granted files are actually read;
  - disk space (`E174.1`) for pre-write capacity checks and `85F4.1` only where
    capacity is displayed to the user;
  - system boot time (`35F9.1`) because `mach_absolute_time()` is used for
    elapsed-time/timer calculations.
  Do not use wrapper-only reasons such as `0A2A.1` in the app manifest.
- [ ] **Codex:** Add and validate `PrivacyInfo.xcprivacy` with only applicable
  declarations and approved reasons. Do not assume collected-data arrays are
  empty until LRCLIB and every other network recipient's handling is assessed.
- [ ] **Codex:** Inspect every embedded third-party SDK privacy manifest and
  signature requirement.
- [ ] **Codex:** Record whether each embedded SDK, including `onnxruntime`, is on
  Apple's current required-manifest/signature list and the date checked.
- [ ] **Codex:** Document every Store network destination and payload:
  - optional model downloads;
  - optional LRCLIB lookup;
  - any future support or update checks.
- [ ] **Codex:** Draft App Store Connect privacy answers from actual network and
  storage behavior.
- [ ] **Codex:** Draft a public privacy policy matching the Store binary.
- [ ] **User:** Confirm that the privacy description is accurate from the
  publisher's perspective.
- [ ] **Joint:** Publish the privacy policy at a stable HTTPS URL and enter the
  URL/disclosures in App Store Connect.

### Entitlements and capabilities

- [ ] **Joint:** Verify automatic signing and the distribution profile for the
  Store bundle identifier.
- [ ] **Joint:** Verify that
  `com.apple.developer.kernel.increased-memory-limit` is valid for distribution
  and present in the signed archive only when needed.
- [ ] **Codex:** Test correct behavior when additional memory is unavailable.
- [ ] **Codex:** Confirm that background audio is used only for user-visible
  playback/recording behavior and document it for review.
- [ ] **Codex:** Confirm the microphone purpose string matches actual use and
  that denial/revocation paths work.
- [ ] **Codex:** Remove unused document types, capabilities, background modes,
  and entitlements. Store URL-scheme removal is an explicit Phase 1 requirement,
  not a cleanup item.
- [ ] **Codex:** After the user confirms the export-compliance conclusion, set
  `ITSAppUsesNonExemptEncryption` in each plist to the correct value so
  replacement builds do not repeatedly stall for missing compliance.
- [ ] **User:** Confirm whether Atarang uses only exempt encryption supplied by
  the operating system (for example HTTPS and CryptoKit hashing), or provide
  details of any additional cryptography.
- [ ] **Codex:** Review logs and diagnostics for accidental source URLs,
  filenames, or personal information.

### Third-party rights and notices

- [ ] **Codex:** Produce a dependency and model bill of materials for each
  flavor, including exact versions, origins, checksums, licenses, and whether
  each component is bundled or downloaded.
- [ ] **Codex:** Verify that full required copyright and license notices are
  actually copied into each app bundle and readable in Settings.
- [ ] **Codex:** Replace the current shared notices symlink with real
  per-flavor notice resources owned by their respective source/resource roots.
- [ ] **Codex:** Repair and split notices so the Store build lists only shipped
  Store components and the GitHub build includes Python, yt-dlp, YoutubeDL,
  FFmpeg, and every other additional shipped component.
- [ ] **Codex:** Determine the exact FFmpeg configuration and resulting LGPL/GPL
  obligations, including any source/relinking obligations, for the GitHub
  artifact. This blocks a GitHub binary release but not the Store release once
  FFmpeg is proven absent there.
- [ ] **Codex:** Carry forward the Phase 0 model-rights dispositions and treat
  unclear, noncommercial, missing, or incompatible rights as exclusion blockers.
- [ ] **Codex:** Prepare a rights-evidence folder containing upstream license
  snapshots and attribution requirements.
- [ ] **User:** Make the final legal/business determination that Atarang has the
  right to distribute each model, conversion, icon, screenshot, and other
  third-party asset.
- [ ] **User:** Obtain written permission or replace an asset when Codex flags
  insufficient distribution rights.

Exit criteria:

- Privacy manifest validation passes.
- App Store privacy answers and privacy policy have reviewable drafts.
- Signed entitlements match actual features.
- No unresolved distribution-rights issue remains.

## Phase 5 — Store product quality and metadata

### Product readiness

- [ ] **Codex:** Review onboarding and empty states for a first-time Store user
  with no existing GitHub library.
- [ ] **Codex:** Make the Store experience complete without an account, demo
  server, or pre-existing files.
- [ ] **Codex:** Verify the required Phase 2 demo track works from a clean
  install and that its rights evidence is included in the release evidence.
- [ ] **Codex:** Test downloads only for optional models approved for Store v1:
  interruption, resume/retry, checksum failure, low storage, offline launch,
  and provider outages.
- [ ] **Codex:** Confirm app behavior remains useful with online lyrics disabled
  and optional models unavailable.
- [ ] **Codex:** Measure launch time, memory, heat, battery behavior, storage
  growth, archive size, download size, and installed size.
- [ ] **Codex:** Report the bundled HTDemucs contribution separately. If
  processed size or first-download usability is unacceptable, prepare a
  bundled-versus-first-run-download recommendation before screenshots and
  review notes are finalized.
- [ ] **Codex:** Audit VoiceOver, Dynamic Type, contrast, Reduce Motion, touch
  targets, keyboard dismissal, rotation, and iPad layout.
- [ ] **Codex:** Treat as release-blocking any crash, data loss, hang longer than
  10 seconds without progress/cancellation UI, or VoiceOver-unreachable control
  on the clean-install → demo/file import → separate → play path.

### App Store materials

- [ ] **Codex:** Draft the app name, subtitle, promotional text, description,
  keywords, support text, copyright, category recommendation, and release
  notes.
- [ ] **Codex:** Draft the age-rating questionnaire answers based on the app's
  actual features.
- [ ] **Codex:** Draft export-compliance answers based on linked encryption and
  network libraries.
- [ ] **Codex:** Generate current Store screenshots from the Store scheme for
  required device sizes.
- [ ] **Codex:** Defer an App Preview for v1 unless screenshots cannot explain
  the core experience; if created, use only Store-build screen recordings.
- [ ] **Codex:** Prepare detailed Notes for Review explaining:
  - local Files import;
  - on-device separation and analysis;
  - optional model downloads;
  - optional LRCLIB behavior;
  - microphone and background audio use;
  - memory-intensive operations, the fastest recommended model, expected
    wall-clock time on the review device class, and the exact demo-track path.
- [ ] **Codex:** Prepare exact clean-install review steps using the bundled demo
  track; no external download or Files setup may be required for the primary
  review path.
- [ ] **User:** Choose free/paid pricing, initial territories, primary category,
  and final marketing tone.
- [ ] **User:** Confirm the final age-rating, export-compliance, content-rights,
  and privacy attestations.

Exit criteria:

- All App Store Connect text and media are ready to paste/upload.
- A reviewer can exercise the core app from a clean install using supplied,
  legally distributable input.

## Phase 6 — Verification and release automation

### Automated tests

- [ ] **Codex:** Run all shared unit tests against both flavors where relevant.
- [ ] **Codex:** Add Store tests proving YouTube URL ingestion and GitHub-only
  intents are unavailable.
- [ ] **Codex:** Add GitHub tests proving its adapter still functions at the
  source-neutral ingestion boundary.
- [ ] **Codex:** Add library migration and compatibility tests.
- [ ] **Codex:** Add privacy-manifest, notices, entitlements, bundle ID, version,
  dependency, and forbidden-trace checks to the release script.
- [ ] **Codex:** Refuse any Store export unless the built/exported artifact's
  bundle identifier equals the permanent Store identifier, its flavor setting
  is Store, its plist has no URL types, and all Store inventory fixtures match.
  Scheme name alone is not an identity or safety gate.

### Device and release matrix

- [ ] **Codex:** Build and test the Store scheme on supported simulators.
- [ ] **Joint:** Run the Store build on available physical devices.
- [ ] **Joint:** Cover at least one lower-memory supported device and one current
  device. Codex operates the build/test tools where available; the user supplies,
  unlocks, trusts, and provisions devices as needed.
- [ ] **Codex:** Test clean install, upgrade, import, separation variants,
  playback, recording, export/share, lyrics, chords, backup flags, storage
  cleanup, interruption, background/foreground transitions, and restoration
  after termination.
- [ ] **Joint:** Validate Release behavior with optimizations and distribution
  signing; Debug success is not sufficient.
- [ ] **Joint:** Run Xcode archive/distribution validation. Codex diagnoses and
  resolves technical errors and actionable warnings; the user supplies any
  account authentication or portal action.
- [ ] **Codex:** Export the candidate with a checked-in,
  non-secret `ExportOptions-AppStore.plist`, run the complete trace scan against
  that exact `.ipa`, and record its SHA-256.
- [ ] **Joint:** Upload the exact scanned `.ipa` using an authenticated
  command-line/App Store Connect upload path. Do not resubmit a separately
  generated Organizer artifact under the same evidence record.
- [ ] **Codex:** Confirm marketing version/build number are unique and match App
  Store Connect.

### TestFlight

- [ ] **Joint:** Upload only the validated App Store archive to TestFlight.
- [ ] **Codex:** Prepare internal test instructions and a focused regression
  checklist.
- [ ] **User:** Select internal team testers for the first candidate.
- [ ] **Joint:** Use external TestFlight only if broader testing is needed;
  external testers require Beta App Review and are not a prerequisite for the
  first App Store submission.
- [ ] **Joint:** Triage TestFlight feedback and crash reports; Codex implements
  fixes and repeats the entire release gate for every replacement build.

Exit criteria:

- The exact candidate build passes automated, simulator, device, archive,
  privacy, entitlement, and forbidden-trace verification.
- TestFlight has no unresolved release-blocking issue.

## Phase 7 — App Store Connect and submission

### App Store Connect finalization

- [ ] **Joint:** Reconfirm the App Store Connect record matches the permanent
  Store identifier selected in Phase 0.
- [ ] **Joint:** Enter the prepared app information, availability, pricing,
  privacy disclosures, privacy-policy URL, support URL, screenshots, and build.
- [ ] **User:** Provide final answers to App Store Connect's legal attestations.

### Submission

- [ ] **Codex:** Perform a final policy delta check on submission day.
- [ ] **Codex:** Verify App Store Connect processed the same bundle ID, version,
  and build number as the scanned/exported candidate, and attach the uploaded
  `.ipa` checksum to that evidence record.
- [ ] **Joint:** Add the build and prepared Notes for Review to the submission.
- [ ] **User:** Press the final “Submit for Review” action unless an authorized
  App Store Connect automation is deliberately configured later.
- [ ] **Joint:** Respond truthfully and specifically to App Review questions.
  Codex can draft responses and assemble technical evidence.
- [ ] **Codex:** Diagnose and fix technical or metadata rejections.
- [ ] **User:** Handle contractual, rights, identity, pricing, or policy appeals,
  using drafts/evidence prepared by Codex.
- [ ] **Joint:** Choose manual, automatic, or phased release after approval.

Exit criteria:

- The app is approved and released in the selected territories.
- The released build number matches the validated candidate.

## Phase 8 — GitHub build and ongoing dual-release maintenance

- [ ] **Codex:** Create a separate GitHub Release build/archive workflow that
  cannot use Store export settings or the Store bundle identifier.
- [ ] **Codex:** Document realistic iOS installation/signing requirements; do
  not imply that a raw `.ipa` is universally installable.
- [ ] **Codex:** Preserve prominent permission/copyright and YouTube terms
  warnings in the GitHub build and README.
- [ ] **Codex:** Publish separate release notes for Store and GitHub flavors.
- [ ] **Codex:** Ensure GitHub screenshots and docs cannot be mistaken for the
  Store product page.
- [ ] **Codex:** Run shared tests for every release and flavor-specific tests
  only against the relevant target.
- [ ] **Codex:** Repeat the Store forbidden-trace scan for every Store update,
  including dependency-only updates.
- [ ] **Codex:** Re-audit privacy manifests, SDK requirements, licenses, model
  hosting, and Apple policies before every Store submission.
- [ ] **User:** Decide whether and where to publish the GitHub binary after
  considering the continuing third-party service-policy risk.

## Release evidence Codex will maintain

For each Store candidate, retain:

- source commit and clean-working-tree proof;
- Xcode, SDK, deployment target, dependency lockfile, and scheme/configuration;
- test results and known-issue disposition;
- device/simulator matrix;
- archive validation log;
- exported `.ipa` checksum;
- complete app-bundle inventory;
- forbidden-trace scan report;
- signed entitlements and processed Info plist;
- privacy report and final privacy manifest;
- third-party bill of materials and rights/notice evidence;
- screenshots and metadata associated with that build;
- App Review notes and reviewer test instructions;
- TestFlight findings and their resolution.

Secrets, signing private keys, App Store credentials, and private personal data
must not be committed to this evidence.

## Definition of done

The App Store release is complete only when all of the following are true:

1. The Store app can complete its core journey using a user-selected local audio
   file.
2. The Store archive has no linked, bundled, compiled, generated, or dormant
   YouTube/downloader functionality or references.
3. The exported `.ipa` passes the automated forbidden-trace gate.
4. Privacy manifests, disclosures, policy, entitlements, permissions, licenses,
   and notices match the exact binary.
5. Release tests pass on the agreed simulator/device matrix.
6. Store metadata and support material show only Store functionality.
7. The exact validated build is uploaded, approved, and released.
8. GitHub and Store release pipelines cannot be confused accidentally.

## Primary external references

- Apple App Review Guidelines:
  <https://developer.apple.com/app-store/review/guidelines/>
- Apple upcoming submission requirements:
  <https://developer.apple.com/news/upcoming-requirements/>
- Apple privacy manifest documentation:
  <https://developer.apple.com/documentation/bundleresources/privacy-manifest-files>
- App Store Connect app privacy:
  <https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/>
- App Store Connect build upload:
  <https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/>
- YouTube API Services policies:
  <https://developers.google.com/youtube/terms/developer-policies>
- YouTube developer policy guidance:
  <https://developers.google.com/youtube/terms/developer-policies-guide>
