# User-Supplied Chord Charts

Plan for importing, preserving, aligning, selecting, simplifying, and correcting
user-supplied chord charts without replacing Atarang's locally detected chart.

This document records the product decisions, research background, architecture,
implementation phases, risks, and acceptance criteria for the feature. Research
links and service constraints were checked on 28 July 2026.

## Status

- [ ] Not started
- [~] In progress
- [x] Complete
- [!] Blocked or needs a decision

Update the checkboxes as work progresses. Each phase must leave the app usable
without requiring a later phase to repair its data or UX.

## Goal

A song may have several independent chord charts:

- Atarang's local audio analysis.
- One or more charts pasted or imported by the user.
- In the future, a chart returned by an explicitly enabled and legally usable
  online source.

The user chooses which chart is active for that song. The selected chart drives
the Chords stage and Sheet stage and supports the same transposition,
simplification, capo, chord-shape, seeking, looping, and correction features as
the detected chart.

Importing never replaces, mutates, or deletes Atarang's detected chart.
Re-running chord analysis updates only the detected chart. User-supplied charts
are user data and are never invalidated by a detector version change.

## Non-goals

- Scraping Ultimate Guitar, Chordify, Songsterr, or another chart site.
- Fetching a chart from an undocumented or private endpoint.
- Shipping a bundled database of third-party chord charts.
- Importing guitar tablature or complete notation as playable tablature.
- Making audio analysis silently rewrite the chords supplied by the user.
- Automatically applying a correction made in one chart to every other chart.
- Replacing or silently modifying the song's active lyrics when a chord chart
  also contains lyric text.
- Requiring a server or account for paste, file import, parsing, alignment, or
  playback.

MusicXML chord-symbol import is a useful later extension, but ChordPro and smart
text paste are the formats covered by the first implementation.

## Product decisions

- [x] **Detected and supplied charts coexist.** They are independently stored,
      selected, corrected, renamed, re-aligned, and removed.
- [x] **Selection is per song.** Switching songs restores the chart previously
      selected for each one.
- [x] **The selected chart uses the complete display pipeline.** Transposition,
      complexity, passing-chord removal, inversion hiding, capo, shapes, bars,
      ribbon, Sheet, seeking, and looping are source-agnostic.
- [x] **Corrections belong to one chart.** A correction made while an imported
      chart is selected changes only that chart.
- [x] **Detected and user-owned storage remain separate.** The existing
      `chords.json` remains detector output; a new user-data file owns imported
      charts and source selection.
- [x] **ChordPro is the canonical interchange format.** Smart paste also
      understands common chords-over-lyrics and bar-chart text.
- [x] **Imported chord labels are authoritative.** Audio evidence helps align
      them to the recording and exposes disagreements. It does not silently
      substitute Atarang's answer.
- [x] **Imported lyric text is an alignment anchor, not a lyrics replacement.**
      Adding those words to `LyricsStore` must be a separate, explicit action if
      that capability is ever offered.
- [x] **A chart is previewed before it is added.** The preview reports parsed
      chords, unsupported symbols, inferred metadata, alignment quality, and
      likely arrangement mismatches.
- [x] **No source-specific Ultimate Guitar integration.** The product accepts a
      chart the user created or is permitted to use; it does not instruct a
      service-specific extraction flow or imply a partnership.
- [x] **All first-party processing stays on device.** Paste, file parsing,
      lyric matching, beat mapping, chroma scoring, and alignment require no
      Atarang backend.

## Current architecture

### Chord storage and display

`ChordStore` currently exposes one `SongChords?`, loaded from and saved to
`chords.json`. `Analyse Again` replaces the detected result except where
individual segments carry `isUserEdited`.

`SongChords` is already the correct runtime currency for an active chart:

- A sorted list of absolute, source-song-time `ChordSegment` values.
- A musical key.
- Chart and segment confidence.
- Source stems for detected analysis.
- Transposition, lookup, bar construction, correction, and re-analysis
  resolution.

Both Chords and Sheet apply display transformations after loading the stored
chart:

1. Transpose by the player's current pitch shift.
2. Apply `ChordPlayability` options.
3. Construct bars, ribbon, shapes, vocabulary, or the lyric/chord sheet.

This is the central leverage point. An imported chart only needs to become a
valid timed `SongChords`; the rendering and practice features do not need a
separate implementation.

### Audio evidence

`ChordDetector` already provides most of the signal-processing foundation:

- A harmonic-stem analysis mix.
- Harmonic and bass chromagrams.
- Beat-averaged pitch-class vectors.
- Chord-template similarity scores.
- Viterbi decoding.
- Key estimation and per-segment confidence.

The importer should reuse the feature extraction and scoring stages. It needs a
different decoder because its state space is the ordered external chart rather
than every detectable chord.

### Lyrics and Sheet

`SongLyrics` stores one active lyric set with provenance such as manual, LRC,
YouTube captions, or LRCLIB. It does not currently preserve several alternative
lyric sets.

`ChordSheet` maps chord times to positions in lyric lines. User-chart alignment
needs the inverse operation:

- Match imported lyric lines to the active `SongLyrics`.
- Convert a chord's character position into a word or line time.

Word timings provide exact anchors. Line-only timings provide a bounded
interpolation. Untimed lyrics can still help identify song structure but cannot
directly place chords in time.

## Proposed data model

Names are provisional; keep responsibilities even if implementation names
change.

### Detected chart

Keep the existing detector artifact:

```text
chords.json
└── SongChords
```

It remains versioned analysis output. `Analyse Again` reads and writes only this
file. Existing pre-feature libraries remain readable without migration.

### User chart collection

Add a user-owned file beside the original:

```text
user-chords.json
└── UserChordCollection
    ├── selectedSource
    └── charts[]
```

Suggested shape:

```swift
struct UserChordCollection: Codable, Equatable {
    var schemaVersion: Int
    var selectedSource: ChordChartSelection
    var charts: [UserChordChart]
}

enum ChordChartSelection: Codable, Hashable {
    case detected
    case user(UUID)
}

struct UserChordChart: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var origin: UserChordOrigin
    var importedAt: Date
    var updatedAt: Date
    var sourceMetadata: ImportedChordMetadata
    var document: ImportedChordDocument
    var alignment: ChordChartAlignment?
    var chords: SongChords?
}
```

`user-chords.json` is user data, not analysis cache:

- Read it without the `AnalysisArtifact` version gate.
- Write atomically after every user mutation.
- Include it in library integrity checks and storage accounting.
- Never delete it because a parser, detector, or alignment version changed.
- Preserve a parse/alignment version so stale derived output can be rebuilt
  from the stored document rather than discarded.

The normalized imported document should be retained so a chart can be
re-aligned when lyrics, beat timing, or the alignment algorithm improves. The
original text may also be retained locally for lossless reparsing, provided the
import UI makes clear that the user must have permission to store it.

### Runtime store

Refactor `ChordStore` conceptually into:

```text
detectedChords: SongChords?
userCollection: UserChordCollection
selectedSource: ChordChartSelection
activeChords: SongChords?
```

For minimum view churn, the existing `chords` property may become the computed
active chart while new explicit properties expose `detectedChords` and
`userCharts`. Mutation methods must name their target rather than relying on an
ambiguous property:

- `select(_:)`
- `addUserChart(_:)`
- `renameUserChart(_:)`
- `replaceAlignment(for:with:)`
- `correctActive(...)`
- `removeDetectedChart()`
- `removeUserChart(id:)`
- `detect(using:)`

If the selected source disappears or has no usable alignment, fall back in this
order:

1. Detected chart, when present.
2. Most recently used aligned user chart.
3. No active chart.

Persist the repaired selection so the fallback does not repeat on every load.

### Provenance and confidence

Do not overload detector confidence with import alignment quality.

Chart provenance should distinguish:

- Local detection.
- Pasted chart.
- ChordPro file.
- A future MusicXML file.
- A future approved online source.

Imported alignment should independently record:

- Parse coverage.
- Lyric-anchor coverage.
- Beat/grid coverage.
- Audio agreement.
- Overall alignment confidence.
- Whether repeat expansion or skipped material was inferred.
- Warnings and unresolved source events.

An imported `ChordSegment.confidence` may drive existing dimming only after its
meaning is defined as placement confidence. Source-specific UI must still say
what the number means.

### Corrections

Keep `isUserEdited` at segment level, scoped to its containing chart.

- A detected correction survives detected re-analysis using the existing merge
  behaviour.
- An imported correction survives re-alignment. Re-alignment must write the
  corrected range over the fresh alignment, analogous to detected
  re-analysis.
- The passing-chord filter must continue to preserve edited segments.
- Cross-chart correction is out of scope until it is an explicit user action
  with a preview.

## Rich chord representation

### Problem

The current `ChordQuality` enum represents:

- Major
- Minor
- Dominant seventh
- Minor seventh
- Major seventh
- Suspended fourth
- Diminished
- Power

External charts commonly add:

- `sus2`, `6`, `m6`, `9`, `m9`, `maj9`
- `add2`, `add4`, `add9`
- `aug`, `dim7`, `m7b5`
- altered fifths, ninths, elevenths, and thirteenths
- omitted degrees
- slash bass notes
- parentheses and spelling aliases

Adding an enum case for every legal suffix does not scale and couples display
vocabulary to detector vocabulary.

### Target

Separate representable chords from detectable chords.

A chord should contain:

- Root pitch class.
- A semantic chord formula or descriptor.
- Optional bass pitch class.
- Enough normalized notation to render and transpose it.

The descriptor should express:

- Base quality or third: major, minor, suspended, power, omitted.
- Fifth alteration: perfect, flat, sharp, omitted.
- Seventh kind.
- Extension.
- Added, altered, and omitted degrees.
- Canonical intervals for audio comparison and future voicing.

The detector keeps a deliberately small static set of detectable descriptors.
The parser and UI can represent a much larger set.

### Behaviour

- `Full` preserves the complete imported symbol.
- `Simple` reduces the semantic formula to an honest triad or nearest stable
  base rather than truncating a string.
- `Beginner` searches known playable shapes and reports when no faithful shape
  exists.
- `Power` uses the root and fifth.
- Hiding inversions removes only the bass component.
- Transposition changes root and bass, never the suffix semantics.
- Chord shapes render an exact known voicing when one exists and otherwise
  offer a labelled simplification; they never invent a misleading diagram.
- The source key controls flat/sharp preference. Nashville and Roman forms are
  resolved through the source key before storage as sounding chords.

### Capo semantics

Imported charts frequently print shapes rather than sounding harmony.

If a chart says `Capo 2` and prints `G`, the sounding chord is `A`. Import must:

1. Parse the printed chord shape.
2. Add the source capo to store the sounding chord.
3. Retain source capo and printed notation as provenance.
4. Feed sounding chords into Atarang's normal display pipeline.

This allows the user to keep the source capo, choose a different capo, or shift
the audio without corrupting musical pitch.

## Import formats

### ChordPro

Support the open ChordPro text format first. Common extensions include:

- `.cho`
- `.crd`
- `.chopro`
- `.chordpro`
- `.pro`
- `.txt`

Required first-pass features:

- Chords embedded in lyric lines: `[Am]words`.
- Title, artist, key, capo, tempo, duration, and time metadata.
- Section environments and common short/long directive aliases.
- Comments and annotations without misclassifying them as chords.
- Chord grids with bars, beat cells, continuations, and basic repeats.
- `N.C.` / no-chord.
- Slash chords.
- Nashville and Roman roots when a key is known.
- Unknown directives preserved or ignored with a warning, not treated as
  lyrics.

Defer custom chord-diagram definitions, delegated image/notation environments,
and complete layout styling. They do not affect Atarang's timed harmony.

Official format references:

- <https://www.chordpro.org/chordpro/chordpro-introduction/>
- <https://www.chordpro.org/chordpro/chordpro-chords/>
- <https://www.chordpro.org/chordpro/directives-env_grid/>

### Smart paste

Recognize common unmarked text without requiring the user to convert it:

```text
[Verse 1]
    G             D/F#
Words begin here and continue
```

```text
| G . . . | D/F# . . . | Em7 . . . | C . . . |
```

```text
G  D/F#  Em7  C
```

Line classification should distinguish:

- Metadata.
- Section labels.
- Chord-only lines.
- Lyric lines.
- Inline ChordPro lines.
- Bar grids.
- Guitar tablature.
- Comments, performance notes, and decorative text.

Important parser rules:

- Expand tabs consistently before measuring columns.
- Preserve Unicode grapheme positions.
- Normalize `#`, `♯`, `b`, and `♭`.
- Recognize common chord aliases without accepting ordinary words as chords.
- Reject guitar-tab staff lines such as `e|-----` and fret-number runs.
- Pair a chord-only line with the following lyric line when their structure is
  plausible.
- Treat `x2`, `repeat`, `let ring`, strumming notes, and fingering blocks as
  annotations.
- Assign a parse confidence to every recognized token and line.
- Never discard an unknown chord silently.

### Imported document

Parsing must produce a source-relative document before any song times are
assigned:

```text
ImportedChordDocument
├── metadata
├── sections
├── lyric anchors
├── bars and beat cells
├── ordered chord events
├── repeat/volta instructions
└── warnings
```

A chord event location may be:

- A character position in a lyric line.
- A cell and beat within a bar.
- An ordinal position in a chord-only sequence.
- Unresolved.

Keeping parsing independent from alignment makes both stages testable and lets
one imported document be aligned again without reparsing.

## Alignment

Alignment converts an `ImportedChordDocument` into a timed `SongChords` for the
specific recording open in Atarang.

### Evidence hierarchy

Use the strongest available evidence first:

1. Exact imported word matched to an active word timestamp.
2. Imported lyric character position within a matched timed line.
3. Explicit ChordPro bar/beat cell mapped to a reliable beat grid.
4. Section and line order.
5. Chord-template agreement with beat-synchronous audio.
6. Even interpolation only as a labelled fallback.

No single evidence type is mandatory. A chart may align through lyrics, bars,
audio, or a combination.

### Lyric matching

Normalize only for matching, never for display:

- Case-fold.
- Collapse whitespace.
- Normalize punctuation and apostrophes.
- Optionally ignore repeated section labels and common annotations.

Use sequence alignment rather than independent fuzzy lookup so repeated chorus
lines, omitted verses, and rearranged sections do not all map to the first
matching line. Scoring should consider:

- Token similarity.
- Neighbouring matched lines.
- Section labels.
- Document order.
- Existing timestamps.

For a matched line:

- Word-timed lyrics map the imported character position to the matching word's
  start.
- Line-timed lyrics interpolate between this line and the next timed line,
  pulled to a word boundary.
- Untimed lyrics provide order and structure but no absolute time.

Imported words remain inside the chart document as anchors; they do not replace
`SongLyrics`.

### Beat and bar mapping

When the document has explicit bars:

- Map bar starts to reliable detected downbeats.
- Map grid cells to beats or equal subdivisions defined by the source shape.
- Expand `%`, `%%`, ordinary repeats, and supported voltas into a linear
  candidate arrangement.
- Respect source time-signature changes when representable.
- Warn rather than force the mapping when source bar count and recording bar
  count diverge substantially.

When the beat grid is unreliable, do not manufacture exact bars. Fall back to
lyric/audio alignment and label the result.

### Audio-guided sequence alignment

Expose reusable beat evidence from `ChordDetector`:

```text
BeatChordEvidence
├── beat start/end
├── harmonic chroma
├── bass chroma
├── energy
└── score(chord descriptor)
```

Build a constrained dynamic-programming aligner whose state is the ordered
external chord event and whose observations are song beats.

Allowed transitions should cover:

- Hold the current chart chord for another beat.
- Advance to the next chart chord.
- Skip a low-confidence source event with a penalty.
- Repeat a marked source section.
- Match a repeated lyric section to another occurrence.
- Enter or leave unmatched instrumental material.

Lyric and bar anchors constrain legal regions. Audio template scores select the
best timing inside those regions.

The aligner must not change the imported chord label. If a supplied `Bm7`
aligns best where unrestricted detection prefers `D`, the imported chart still
contains `Bm7`; the UI records and displays the disagreement.

### Arrangement mismatch

Detect and report likely wrong-version imports using:

- Source duration versus recording duration.
- Lyric sequence coverage.
- Section order.
- Required skips or repeats.
- Aggregate audio agreement.

Do not offer a high-confidence “Use Chart” result when the evidence says it is
probably a live, acoustic, radio-edit, remastered, or otherwise different
arrangement. The user may save it as an unaligned draft or continue after an
explicit warning.

### Source pitch

A chart may be written at a different pitch from the recording: a guitar tuned
down, a capo the transcriber assumed and did not write, or simply another
version. Every chord is then placed correctly and every chord is wrong under the
fingers, which reads as "the import is broken" when it is not.

Alignment compares the placed chart against the local analysis of the recording
and reports the offset that agrees best. It is never applied on its own —
imported labels are authoritative, and a chart a semitone above the record is
what someone actually played. The import preview states what was found, offers
to match the recording, and records the applied offset so re-alignment keeps the
user's decision.

### Re-alignment

Re-alignment:

1. Reuses the stored normalized document.
2. Builds a fresh timed chart using current lyrics, beat grid, and algorithm.
3. Reapplies corrections made within that imported chart over their edited
   ranges.
4. Shows a before/after preview.
5. Replaces only that chart's derived alignment after confirmation.

## User experience

### Chords empty state

Offer two equally valid starting points:

- `Find the Chords`
- `Import a Chord Chart`

The first remains entirely local detection. The second opens paste/file import.

### Source selector

When only one usable chart exists, retain the compact current header.

When alternatives exist, make the source badge selectable:

```text
My chart ▾    E-flat major
```

The selector lists:

- `Atarang analysis` with detected confidence and source stems.
- Named imported charts with origin and alignment status.
- `Add another chart…`
- `Manage charts…`

Switching charts must not stop playback, seek, clear a loop, change speed/key,
or modify display preferences.

### Import flow

1. **Input**
   - Paste text or choose a file.
   - State that imports remain on device.
   - State that the user should import only material they created or may use.
2. **Parse preview**
   - Show title/key/capo/sections.
   - Show recognized and unknown chord symbols.
   - Allow source key, capo, or notation corrections.
3. **Alignment**
   - Explain whether lyrics, beats, and audio are being used.
   - Support cancellation.
4. **Result preview**
   - Show chart name.
   - Show chord and section counts.
   - Show alignment quality and warnings.
   - Mark estimated placements, inferred repeats, unsupported symbols, and
     strong audio disagreements.
5. **Add Chart**
   - Adds a new chart and selects it.
   - Does not modify detection or lyrics.

Importing the same file or text again should offer:

- Add as another chart.
- Update an existing selected chart after preview.
- Cancel.

### Chart management

Support:

- Rename.
- Select.
- Re-align.
- Inspect source metadata and warnings.
- Export as ChordPro when representable.
- Remove one imported chart.
- Remove detected analysis separately.

Rename destructive menu labels so `Remove Chords` cannot ambiguously delete
more than the selected target.

### Corrections and comparison

The correction sheet operates on the active chart and states its source.

When both detected and imported charts exist, a held chord may additionally
show:

```text
Imported chart: Bm7
Atarang analysis: D
Position: matched to a timed lyric word
```

Comparison is explanatory, not an automatic merge. A later explicit action may
copy a correction to another chart after showing affected ranges.

### Source badges

Use source-specific language:

- `Detected locally · uncertain`
- `Imported ChordPro · aligned`
- `Pasted chart · some positions estimated`
- `Imported · possible different arrangement`

Do not call an imported chart “certain” merely because it came from a person,
and do not call it “uncertain” using detector confidence.

## Privacy, copyright, and service boundaries

### Product boundary

The importer is a general-purpose parser for user-supplied content:

- No source website is contacted.
- No browser cookies, credentials, or page data are read.
- No URL extraction is offered.
- No third-party brand appears as an integration without permission.
- No imported chart is uploaded by Atarang.

Suggested disclosure:

> Import a chart you created or are allowed to use. Atarang reads and aligns it
> on this device; it does not contact the chart's source.

Ultimate Guitar's current terms limit reproduction and storage of its content
outside expressly permitted uses, and Chordify prohibits automated collection
without permission. A generic paste feature does not grant the user rights
their source did not grant. It should not be marketed as a workaround.

References:

- <https://www.ultimate-guitar.com/about/tos.htm>
- <https://chordify.net/pages/terms-and-conditions/>
- <https://www.copyright.gov/comp3/docs/3-15-19/compendium-draft.pdf>

The US Copyright Office notes that common chord progressions and standard
harmonies may be unprotectable, but that does not make lyrics, arrangements,
compilations, or an entire chord-chart page free to reproduce.

### Online landscape

There is no clean, comprehensive, permissively licensed equivalent of LRCLIB
for chord charts.

#### Songle

Songle is the closest credible experimental service:

- Roughly 2.85 million registered songs as of the research date.
- Timed automatic chord, beat, melody, and structure analysis.
- User corrections.
- API/widget access.

Constraints:

- Research/demonstration service with no permanence guarantee.
- Attribution required.
- Noncommercial use only without prior written permission.
- New YouTube URLs cannot be registered.
- Not suitable as the storage or availability foundation of this feature.

References:

- <https://songle.jp/>
- <https://widget.songle.jp/docs/v1?lang=en>
- <https://api.songle.jp/terms_of_use.pdf>
- <https://docs.songle.jp/en/help/>

An optional Songle experiment can be considered after Phases 1–4 for the
personal sideloaded build, behind a separate opt-in disclosure. It is not part
of this plan's core implementation.

#### SongSelect

SongSelect offers licensed ChordPro downloads for many songs in its worship
catalog to eligible subscribers. It is a good example of a user-authorized file
source and a reason to support ChordPro well, but it is a niche catalog and its
subscription/copy limits remain the user's responsibility.

References:

- <https://fr.ccli.com/songselect/?lang=en>
- <https://onsongapp.zendesk.com/hc/en-us/articles/360044674693-Importing-ChordPro-files-from-SongSelect>

#### Commercial analysis

Music AI offers a production chord-timeline API with several pop/jazz
complexity classes and bass detection. It requires sending audio to a
commercial service, managing API credentials through a backend, and accepting
its pricing and privacy model. It overlaps Atarang's local detector and conflicts
with the app's private-by-design identity, so it is not part of Phases 1–4.

References:

- <https://music.ai/modules/transcription/chords/>
- <https://music.ai/docs/api/file-formats/>

#### Hooktheory and large datasets

Hooktheory's public API exposes chord transition trends and songs containing a
progression, not complete per-song charts.

Chordonomicon contains roughly 680,000 section-labelled chord sequences, but it
is noncommercial, untimed, and derived from scraped user-generated sources.
Its dataset label does not resolve rights inherited from the underlying
material. It must not become a shipped Atarang catalog.

References:

- <https://www.hooktheory.com/api/trends/docs>
- <https://huggingface.co/datasets/avgtrash/Chordonomicon>
- <https://arxiv.org/abs/2410.22046>

## Phase 0 — Contracts, fixtures, and baselines

**Goal:** Freeze current behaviour and define the new boundaries before
changing persisted or musical types.

### Work

- [ ] Record the current `SongChords`, `ChordStore`, `ChordsStage`,
      `SheetStage`, `ChordPlayability`, and `ChordShapes` call graph.
- [ ] Add synthetic fixtures for every currently supported chord quality,
      inversions, no-chord, transposition, simplification, capo, corrections,
      bars, and Sheet placement.
- [ ] Add synthetic ChordPro and smart-paste fixtures. Do not use copied
      copyrighted charts in the repository.
- [ ] Define `ImportedChordDocument`, provenance, alignment result, and warning
      contracts independent of SwiftUI.
- [ ] Define which values are user data versus rebuildable derived data.
- [ ] Confirm `user-chords.json` as the filename and add it to song storage,
      integrity, accounting, and backup policy documentation.
- [ ] Specify parse and alignment version behaviour.

### Acceptance criteria

- [ ] Current detected-chord tests pass unchanged.
- [ ] Fixtures cover flat/sharp spellings, slash chords, capo, repeated
      sections, tabs, unknown symbols, and wrong-version material.
- [ ] Every persisted field has a documented owner and invalidation policy.
- [ ] No UI or stored chart behaviour has changed.

## Phase 1 — Rich representable chord model

**Goal:** Represent real imported chord symbols without expanding detector
states recklessly or losing existing playability behaviour.

### Work

- [x] Replace the closed `ChordQuality` dependency with a scalable semantic
      descriptor/formula.
- [x] Preserve source-compatible `Codable` behaviour or update all existing
      development data deliberately, consistent with the pre-1.0 policy.
- [x] Define a small `detectable` descriptor set equivalent to today's detector
      vocabulary.
- [x] Implement a chord-symbol lexer/parser with aliases and Unicode
      accidentals.
- [x] Implement canonical symbol rendering, spoken names, pitch classes, and
      transposition.
- [x] Support at minimum major, minor, power, sus2, sus4, 6, m6, 7, maj7, m7,
      dim, dim7, aug, m7b5, add2/add4/add9, 9/maj9/m9, slash bass, altered
      fifths, and no-chord.
- [x] Refactor `ChordPlayability` to simplify semantic formulas rather than enum
      strings.
- [x] Keep exact known shapes and honest fallback behaviour for rich chords.
- [x] Update correction UI so representable imported chords can be selected or
      entered without presenting hundreds of flat picker rows.
- [~] Add round-trip, alias, transposition, simplification, VoiceOver, and
      malformed-input tests.

### Acceptance criteria

- [ ] Every chord the current detector emits renders and simplifies exactly as
      before.
- [ ] Imported rich chords survive parse → encode → decode → transpose without
      suffix loss.
- [ ] `Full`, `Simple`, `Beginner`, and `Power` produce musically documented
      results for every supported formula.
- [ ] Unknown or partly supported formulas remain visible and labelled; none
      silently becomes a different chord.
- [ ] The detector state count remains intentionally bounded.

## Phase 2 — Independent chart collection and selection

**Goal:** Preserve detected and user-supplied charts side by side and route the
existing feature pipeline through the selected chart.

### Work

- [x] Add `UserChordCollection`, `UserChordChart`, provenance, and selection
      types.
- [x] Add atomic read/write of `user-chords.json`.
- [x] Refactor `ChordStore` to own detected, user, selected, and active state.
- [x] Make detection and re-analysis mutate only the detected slot.
- [x] Make correction mutate only the selected chart.
- [x] Preserve imported corrections across future re-alignment.
- [x] Make Chords and Sheet observe the active chart and chart selection.
- [x] Add a source selector when more than one usable chart exists.
- [x] Add chart rename, select, and targeted remove actions.
- [x] Update empty, error, notice, and source-badge language.
- [x] Add safe fallback when a selected chart becomes unavailable.
- [x] Include the user chart file in integrity checks and storage accounting.

### Acceptance criteria

- [~] Detected and imported synthetic charts coexist and can be switched.
      Transport state during a switch is still only checked by hand.
- [ ] Every display transformation and Sheet output follows the selected chart.
- [~] `Analyse Again` cannot alter any user chart. The mutation surface is
      tested — correction, removal, and detected writes cannot reach a user
      chart — but a full detector run is not exercised in tests.
- [x] Correcting one chart cannot alter another.
- [x] Removing one chart cannot delete another source.
- [x] Relaunch restores the selected source per song, and repairs a
      selection whose chart is gone.
- [x] Existing libraries with only `chords.json` behave exactly as before.

## Phase 3 — Smart Paste and ChordPro import

**Goal:** Add user charts locally from text or files with a trustworthy preview,
without yet requiring the strongest audio-guided alignment.

### Work

- [x] Implement ChordPro directive, lyric-line, chord, and grid parsing.
- [x] Implement smart-paste line classification and chords-over-lyrics pairing.
- [~] Parse key, capo, tempo, duration, time signature, sections, repeats, and
      annotations.
- [x] Convert printed capo shapes to sounding chords while retaining source
      metadata.
- [x] Produce a normalized `ImportedChordDocument` with token/line confidence
      and warnings.
- [x] Add paste and document-picker input.
- [x] Register supported uniform types/extensions where appropriate.
- [~] Build parse preview and editable metadata correction.
- [x] Reject or isolate tablature and non-chart noise.
- [x] Add a deterministic chart-name suggestion and duplicate handling.
- [x] Add ChordPro export for the supported normalized subset.
- [x] Add import accessibility, cancellation, and large-input limits.

### Acceptance criteria

- [ ] Valid ChordPro fixtures parse deterministically.
- [x] Common chords-over-lyrics paste preserves chord-to-character placement.
- [ ] Bar grids preserve bars, beats, holds, and supported repeats.
- [x] Capo conversion produces correct sounding chords, wherever in the file
      the capo is declared, and in prose as well as a directive.
- [x] Guitar tablature is not mistaken for hundreds of chord events.
- [ ] Every ignored directive or unknown chord is surfaced in preview.
- [x] Adding a chart never changes detected chords or active lyrics.
- [ ] Paste and file import work with airplane mode enabled.

## Phase 4 — Lyric, beat, and audio alignment

**Goal:** Turn an imported document into a timed chart for the exact recording,
using all local evidence while keeping the supplied chord labels intact.

### Work

- [x] Implement ordered fuzzy alignment between imported lyric anchors and
      active `SongLyrics`. Global sequence alignment, not greedy per line, so a
      repeated chorus reaches its own occurrence.
- [x] Implement character-to-word timestamp mapping, through a word-level
      alignment of the chart's line to the recording's line rather than a raw
      character offset.
- [x] Implement labelled line-time interpolation.
- [x] Map explicit grid bars/cells to reliable detected beats and downbeats.
- [ ] Expand supported repeats and section occurrences into a candidate linear
      chart.
- [x] Refactor `ChordDetector` to expose reusable beat evidence without
      duplicating audio reads or FFT work.
- [~] Implement constrained chart-to-audio sequence alignment.
- [ ] Support holds, advances, bounded skips, repeated sections, and unmatched
      instrumental regions.
- [x] Calculate parse, placement, anchor, audio-agreement, and overall metrics.
- [x] Detect likely arrangement mismatches, by duration, anchor coverage, and
      audio agreement.
- [x] Detect a chart written at another pitch, report it, and let the user
      match the recording without editing the chart text.
- [x] Build result preview with warnings and disagreement markers.
- [~] Implement non-destructive re-alignment and correction preservation.
- [~] Make long alignment work cancellable. The import preview runs off the
      main actor and cancels on the next keystroke; it does not yet go through
      the shared analysis queue.

### Acceptance criteria

- [x] Word-timed fixtures place source chords on the correct words, including
      where the chart's wording differs from the recording's.
- [x] Bar-grid fixtures place changes on the correct beats.
- [x] Repeated chorus fixtures align to distinct occurrences rather than the
      first matching text.
- [ ] A condensed chart can expand marked repeats into the recording.
- [x] Audio scoring improves timing without changing imported chord labels.
- [ ] Strong source/audio disagreements are visible and testable.
- [x] Wrong-version fixtures produce a warning rather than false high
      confidence.
- [ ] Re-alignment preserves edits and requires confirmation before replacing
      prior derived timing.
- [ ] Alignment cancellation leaves the previous chart and files intact.

## Phase 5 — Comparison, polish, and release validation

**Goal:** Make multiple charts understandable and safe in real practice.

### Work

- [x] Add detected-versus-imported comparison to chord correction details.
- [x] Add chart-level management and source information.
- [ ] Refine fallback and recovery UI for damaged or stale imported data.
- [ ] Add telemetry only through local diagnostics; never log chart text,
      titles, source URLs, or chord sequences.
- [ ] Update README, privacy disclosure, third-party notices if any dependency
      is added, and manual test documentation.
- [ ] Audit VoiceOver, Dynamic Type, contrast, touch targets, and instrument-in-
      hand usability.
- [ ] Run simulator and physical-device regression passes for playback,
      transposition, looping, recording, backgrounding, and relaunch.

### Acceptance criteria

- [ ] A user can always tell which chart is active and where it came from.
- [ ] Switching and comparing charts is possible without stopping practice.
- [ ] Source-specific confidence language is accurate.
- [ ] No imported content appears in diagnostics or logs.
- [ ] The feature works without a network connection.
- [ ] Physical-device testing confirms that importing or aligning cannot
      destabilize audio playback or recording.

## Known gaps

Carried deliberately rather than forgotten. None of them changes what is stored,
so each can be closed without a migration.

- **Instrumental bars are placed by proportion, not by bar number.** A
  written-out interlude in a chart that also has words is spread across the gap
  between the lines around it. Absolute bar numbers are only trusted for a chart
  that is nothing but bars, because a chart's bar 1 is its section's bar 1, not
  the recording's.
- **Beat evidence is session-only.** `ChordDetector` publishes it into
  `ChordStore` in memory and it is cleared when the song closes, so a chart
  imported after a relaunch aligns without audio evidence until analysis runs
  again. Only matters when a song has no lyrics; the import preview says so.
- **ChordPro export is a chord list.** Lyrics, sections, and grids are dropped,
  so the file re-imports to the same sounding chords but does not read like the
  chart it came from.
- **`user-chords.json` is written without a storage-capacity check**, unlike
  every artifact that goes through `writeAnalysis`. Chart count and size are
  also not shown in chart management.
- **Source metadata is shown but not editable** in the import preview, so a
  chart with a wrong printed key or capo has to be corrected in the text.
- **Repeats are not expanded.** `%` and `%%` inside a grid are, but a chart that
  writes a chorus once and marks it `x3` still contributes one occurrence.

## Testing strategy

### Unit tests

- Chord-symbol grammar, aliases, malformed input, and Unicode.
- Semantic interval formulas and transposition.
- Honest simplification for every supported descriptor.
- ChordPro directives, grids, repeats, sections, comments, and unknowns.
- Smart-paste line classification and character columns.
- Capo shape-to-sounding conversion.
- Lyric normalization and ordered fuzzy matching.
- Beat/bar mapping.
- Constrained alignment transitions and scoring.
- Arrangement mismatch metrics.
- Codable round trips and damaged-file handling.

### Integration tests

- Existing detected chart plus two user charts.
- Re-analysis isolation.
- Per-chart corrections.
- Selection persistence and fallback.
- Chords and Sheet using the same selected/transformed answer.
- Import while playback is active.
- Alignment cancellation and atomic publishing.
- Library integrity and storage accounting.

### Fixture policy

Use generated, public-domain, or deliberately synthetic songs and charts.
Repository fixtures must not contain copied commercial lyrics or third-party
chart pages.

Include difficult synthetic cases:

- Same chorus repeated three times.
- Verse omitted from the recording.
- Live intro added before the chart starts.
- Capo chart with slash chords.
- One chord per bar and multiple chords per beat.
- Wrong key metadata.
- Tabs mixed with a small chord legend.
- Unicode flats/sharps and German note naming.
- A rich chord with no known diagram.
- Different-arrangement duration and section order.

## Risks and mitigations

### Chord grammar becomes unbounded

Mitigation: semantic formula plus lossless display fallback; small detector
vocabulary; explicit parser warnings; no attempt to enumerate every suffix as
an enum case.

### Proportional-font paste loses visual columns

Mitigation: preserve actual clipboard whitespace, expand tabs, show a
monospaced preview, combine character anchors with lyric/audio evidence, and
label low-confidence positions.

### Repeated lyrics map to the wrong occurrence

Mitigation: ordered sequence alignment using neighbours, sections, bars, and
audio rather than independent fuzzy lookup.

### The chart is for another recording

Mitigation: duration, structure, anchor coverage, skip/repeat cost, and audio
agreement checks; warn or keep as an unaligned draft.

### Rich chords break shapes or beginner mode

Mitigation: separate accurate representation from available voicings; show the
full symbol and label any simplified playable shape.

### Re-analysis destroys user work

Mitigation: physically separate storage and target-specific mutation APIs;
tests proving detector writes cannot reach user charts.

### Confidence becomes misleading

Mitigation: separate detector confidence, placement confidence, and audio
agreement in both data and copy.

### Copyright or source terms are misunderstood

Mitigation: no scraping, URL import, undocumented endpoints, or source branding;
clear user-authorized-content disclosure; all imports stay local.

### Persistence grows without bound

Mitigation: text and timed chord data are small; show chart count and storage in
management; permit targeted removal; avoid duplicating audio evidence in every
chart.

## Definition of done

The feature is complete when:

- A song can retain Atarang detection and several user charts simultaneously.
- The active chart is selectable and remembered per song.
- Every source uses the same transposition, simplification, capo, shapes,
  Chords, and Sheet pipeline.
- ChordPro and common pasted chart text can be parsed locally with a preview.
- Imported charts align to the exact recording through lyrics, bars, audio, or
  a clearly labelled approximation.
- Imported labels are not silently rewritten by audio analysis.
- Re-analysis, re-alignment, correction, rename, export, and removal affect
  only their explicit target.
- Rich imported chords remain musically and textually honest.
- No core capability depends on an online service, backend, account, or
  third-party catalog.
- Device testing confirms that the feature does not compromise playback,
  recording, library integrity, or user data.
