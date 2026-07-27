import XCTest
@testable import Atarang

final class PracticeSettingsTests: XCTestCase {
    private var library: TemporaryLibrary!

    override func setUpWithError() throws {
        library = try TemporaryLibrary()
    }

    override func tearDown() {
        library = nil
    }

    func testNewSettingsReceiveSafeDefaults() {
        var settings = SongPracticeSettings()
        settings.stage = .lyrics
        settings.playbackRate = 0.75

        settings.validate(duration: 120, availableStems: [.vocals, .instrumental])

        XCTAssertEqual(settings.schemaVersion, SongPracticeSettings.currentSchemaVersion)
        XCTAssertEqual(settings.stage, .lyrics)
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

    func testValidationReportsAMissingTargetInsteadOfSwappingItSilently() {
        var settings = SongPracticeSettings()
        settings.target = .guitar

        let validation = settings.validate(
            duration: 100,
            availableStems: [.vocals, .drums]
        )

        XCTAssertEqual(validation.missingTarget, .guitar)
        XCTAssertEqual(validation.replacementTarget, .vocals)
        XCTAssertEqual(settings.target, .vocals)
        XCTAssertNotNil(validation.targetChangeMessage)
    }

    func testValidationSaysNothingWhenTheTargetSurvives() {
        var settings = SongPracticeSettings()
        settings.target = .bass

        let validation = settings.validate(
            duration: 100,
            availableStems: [.vocals, .bass]
        )

        XCTAssertNil(validation.missingTarget)
        XCTAssertNil(validation.targetChangeMessage)
        XCTAssertEqual(settings.target, .bass)
    }

    func testValidationClampsStemLevelsAndKeepsOnesThisSeparationLacks() {
        var settings = SongPracticeSettings()
        settings.setLevel(0.4, for: .vocals)
        settings.setLevel(0.9, for: .guitar)
        settings.stemLevels["drums"] = 5
        settings.stemLevels["kazoo"] = 0.5

        settings.validate(duration: 100, availableStems: [.vocals, .drums])

        XCTAssertEqual(settings.level(for: .vocals), 0.4)
        XCTAssertEqual(settings.level(for: .drums), 1)
        // Kept, so separating this song 6-stem again finds the guitar fader
        // where it was left.
        XCTAssertEqual(settings.level(for: .guitar), 0.9)
        XCTAssertNil(settings.stemLevels["kazoo"])
    }

    func testStoreKeepsSettingsSeparateForEachSong() {
        let first = SongStorage(folderURL: library.folder(named: "first"))
        let second = SongStorage(folderURL: library.folder(named: "second"))
        let store = PracticeSettingsStore()
        var settings = SongPracticeSettings()
        settings.stage = .lyrics
        settings.target = .bass
        settings.playbackRate = 0.5
        settings.setLevel(0.25, for: .drums)

        store.save(settings, to: first)

        XCTAssertEqual(store.load(from: first), settings)
        XCTAssertEqual(store.load(from: second), SongPracticeSettings())

        store.reset(in: first)
        XCTAssertEqual(store.load(from: first), SongPracticeSettings())
    }

    func testDamagedSettingsReadAsDefaultsRatherThanFailing() throws {
        let storage = SongStorage(folderURL: library.folder(named: "song"))
        try Data("{ not json at all".utf8).write(
            to: storage.url(for: SongStorage.practiceFilename)
        )

        XCTAssertEqual(PracticeSettingsStore().load(from: storage), SongPracticeSettings())
    }
}
