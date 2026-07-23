# Practice Tools Phase 0 Test Matrix

## Automated coverage

`AtarangTests/PlaybackStateTests.swift` covers:

- loop-range rejection and clamping;
- rate-aware media position derived from rendered samples;
- loop-boundary position wrapping;
- generation changes that invalidate stale callbacks;
- decoding and sanitizing pre-schema persisted state.

## Playback synchronization

Use a separated track with obvious transients in every available stem. Start
with all stems at equal volume, then repeat with one stem soloed at a time.

| Scenario | Procedure | Expected result |
| --- | --- | --- |
| Complete song | Play from 0 to the end at 100%, then at 50% | Transients remain aligned and the displayed position reaches the end at the transformed rate |
| Repeated playback | Play to the end, restart, and repeat five times | No double start, missing stem, or increasing offset |
| Seeking | While playing, seek to ten positions in both directions | Every stem restarts together and no offset accumulates |
| Pause/resume | Pause for at least ten seconds and resume, ten times | Position freezes while paused and all stems resume together |
| Loop boundary | Set a short transient-heavy loop and run it for 50 passes | One restart per pass, without stale callbacks, double starts, or an audible scheduling gap |
| Transform parity | Play at each supported rate and pitch extreme | Every stem receives the same transform and remains aligned |

## Output routes and lifecycle

Run the synchronization checks relevant to each row on a physical device.

| Environment | Procedure | Expected result |
| --- | --- | --- |
| Built-in speaker | Play, seek, pause, resume, and record | Stable synchronized playback; recorded backing matches the rendered mix |
| Wired/USB headphones | Connect before playback, then repeat; disconnect during playback | Connection plays normally; disconnection pauses safely without a speaker burst |
| Bluetooth A2DP | Connect before playback, seek repeatedly, then switch routes | Route latency may change, but stems remain aligned and position follows rendered audio |
| Bluetooth HFP recording | Record with the Bluetooth microphone route | Recording starts once, backing remains aligned, and both raw files export normally |
| Control Center route change | Change between available outputs during playback | The engine restarts all stems from one render-derived position and does not drift |
| Interruption | Receive a phone/FaceTime interruption while playing and while recording | Playback resumes only when iOS permits; an interrupted recording closes cleanly and never auto-restarts |
| Backgrounding | Background for 30 seconds during playback, then return | Playback follows the configured audio session and the playhead remains accurate |
| Screen lock | Lock for 30 seconds during playback and recording | Playback/recording behavior matches background audio policy; state remains synchronized after unlock |

## Recording and regression

The backing tap is installed on `AVAudioEngine.mainMixerNode`, after every
stem's `AVAudioUnitTimePitch`. It therefore captures the transformed backing
mix exactly once, while the microphone remains in its independent raw file.

For regression coverage:

1. Record a normal full-song take and confirm microphone/backing level editing.
2. Export the take and compare its duration and balance with the preview.
3. Reopen it from Library/History and play the raw mix.
4. Repeat with a custom stem mix and a non-default playback transform.
5. Confirm older track metadata and recordings still open.
