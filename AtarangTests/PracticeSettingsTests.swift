import XCTest
@testable import Atarang

final class PracticeSettingsTests: XCTestCase {
    func testNewSettingsReceiveSafeDefaults() {
        var settings = SongPracticeSettings()
        settings.workspace = .practice
        settings.playbackRate = 0.75

        settings.validate(duration: 120, availableStems: [.vocals, .instrumental])

        XCTAssertEqual(settings.schemaVersion, SongPracticeSettings.currentSchemaVersion)
        XCTAssertEqual(settings.workspace, .practice)
        XCTAssertEqual(settings.playbackRate, 0.75)
        XCTAssertEqual(settings.target, .vocals)
        XCTAssertEqual(settings.preset, .learn)
        XCTAssertEqual(settings.countInClicks, 0)
        XCTAssertEqual(settings.pitchSemitones, 0)
        XCTAssertEqual(settings.metronomeBPM, 120)
        XCTAssertEqual(settings.metronomeSubdivision, .quarter)
        XCTAssertFalse(settings.metronomeEnabled)
        XCTAssertTrue(settings.savedSections.isEmpty)
        XCTAssertNil(settings.loopRange)
    }

    func testPhaseTwoSettingsAreClampedAndSectionsValidated() {
        var settings = SongPracticeSettings()
        settings.pitchSemitones = 40
        settings.metronomeBPM = 500
        settings.metronomeLevel = -1
        settings.metronomeAlignment = 200
        settings.repetitionTarget = -2
        settings.repetitionPause = 20
        settings.tempoRampEvery = 0
        settings.tempoRampStart = 0.9
        settings.tempoRampTarget = 0.6
        settings.savedSections = [
            SavedPracticeSection(name: "  Chorus  ", start: 10, end: 20),
            SavedPracticeSection(name: "Invalid", start: 30, end: 30)
        ]

        settings.validate(duration: 100, availableStems: [.vocals])

        XCTAssertEqual(settings.pitchSemitones, 12)
        XCTAssertEqual(settings.metronomeBPM, 300)
        XCTAssertEqual(settings.metronomeLevel, 0)
        XCTAssertEqual(settings.metronomeAlignment, 100)
        XCTAssertEqual(settings.repetitionTarget, 0)
        XCTAssertEqual(settings.repetitionPause, 10)
        XCTAssertEqual(settings.tempoRampEvery, 1)
        XCTAssertEqual(settings.tempoRampStart, 0.6)
        XCTAssertEqual(settings.savedSections.count, 1)
        XCTAssertEqual(settings.savedSections.first?.name, "Chorus")
    }

    func testPhaseTwoSettingsRoundTrip() throws {
        var settings = SongPracticeSettings()
        settings.pitchSemitones = -3
        settings.metronomeEnabled = true
        settings.metronomeBPM = 132
        settings.metronomeSubdivision = .triplet
        settings.repetitionTarget = 8
        settings.tempoRampEnabled = true
        settings.savedSections = [
            SavedPracticeSection(name: "Solo", start: 42, end: 55)
        ]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(
            SongPracticeSettings.self,
            from: data
        )

        XCTAssertEqual(decoded, settings)
    }

    func testValidationRejectsUnavailableTargetAndInvalidLoop() {
        var settings = SongPracticeSettings()
        settings.target = .guitar
        settings.loopStart = 8
        settings.loopEnd = 8
        settings.isLoopEnabled = true
        settings.playbackRate = 2
        settings.countInClicks = 3
        settings.lastPosition = 200

        settings.validate(duration: 100, availableStems: [.vocals, .drums])

        XCTAssertEqual(settings.target, .vocals)
        XCTAssertNil(settings.loopRange)
        XCTAssertFalse(settings.isLoopEnabled)
        XCTAssertEqual(settings.playbackRate, 1)
        XCTAssertEqual(settings.countInClicks, 0)
        XCTAssertEqual(settings.lastPosition, 100)
    }

    func testStoreKeepsSettingsSeparateForEachSong() {
        let suiteName = "PracticeSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PracticeSettingsStore(defaults: defaults)
        let firstID = UUID()
        let secondID = UUID()
        var settings = SongPracticeSettings()
        settings.workspace = .practice
        settings.target = .bass
        settings.playbackRate = 0.5

        store.save(settings, for: firstID)

        XCTAssertEqual(store.load(for: firstID), settings)
        XCTAssertEqual(store.load(for: secondID), SongPracticeSettings())

        store.reset(for: firstID)
        XCTAssertEqual(store.load(for: firstID), SongPracticeSettings())
    }
}
