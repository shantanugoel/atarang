import XCTest
@testable import Atarang

final class PracticeSettingsTests: XCTestCase {
    func testLegacySettingsReceiveSafeDefaults() throws {
        let legacyJSON = Data(#"{"workspace":"practice","playbackRate":0.75}"#.utf8)
        var settings = try JSONDecoder().decode(
            SongPracticeSettings.self,
            from: legacyJSON
        )

        settings.validate(duration: 120, availableStems: [.vocals, .instrumental])

        XCTAssertEqual(settings.schemaVersion, SongPracticeSettings.currentSchemaVersion)
        XCTAssertEqual(settings.workspace, .practice)
        XCTAssertEqual(settings.playbackRate, 0.75)
        XCTAssertEqual(settings.target, .vocals)
        XCTAssertEqual(settings.preset, .learn)
        XCTAssertEqual(settings.countInClicks, 0)
        XCTAssertNil(settings.loopRange)
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
