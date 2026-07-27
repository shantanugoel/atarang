import XCTest
@testable import Atarang

/// What the user is told when yt-dlp cannot get a video.
///
/// This exists because the honest answer used to be unreachable: yt-dlp handles
/// an extraction failure internally and exits zero, so the first thing that
/// actually failed was reading the file it never wrote, and the alert said
/// `The file "selection.json" couldn't be opened because there is no such
/// file` — an implementation detail, about a video the user never mentioned.
final class SeparationFailureTests: XCTestCase {
    /// The real string yt-dlp produced for a DRM-protected video.
    func testQuotesYouTubesReasonWithoutItsBookkeeping() {
        let message = SeparationFailure
            .extractionFailed("ERROR: [youtube] ILRs2r6lcHY: This video is not available")
            .errorDescription

        let text = try? XCTUnwrap(message)
        XCTAssertEqual(
            text,
            "This video could not be read from YouTube. YouTube said: This video is not available. Videos that are private, region-locked, or DRM-protected cannot be separated."
        )
        XCTAssertFalse(text?.contains("ILRs2r6lcHY") ?? true, "the video id is yt-dlp's bookkeeping")
        XCTAssertFalse(text?.contains("ERROR:") ?? true)
        XCTAssertFalse(text?.contains("selection.json") ?? true)
    }

    func testStillSaysSomethingUsefulWithNoReason() {
        let message = SeparationFailure.extractionFailed(nil).errorDescription
        XCTAssertEqual(
            message,
            "This video could not be read from YouTube. Videos that are private, region-locked, or DRM-protected cannot be separated."
        )
    }

    func testHandlesAReasonWithNoExtractorPrefix() {
        let message = SeparationFailure
            .extractionFailed("ERROR: Requested format is not available")
            .errorDescription
        XCTAssertEqual(
            message?.contains("YouTube said: Requested format is not available."),
            true,
            message ?? "nil"
        )
    }

    /// Whitespace-only output is no reason at all, not an empty quotation.
    func testBlankReasonIsDropped() {
        XCTAssertNil(SeparationFailure.cleaned("   "))
        XCTAssertNil(SeparationFailure.cleaned("ERROR:"))
    }
}
