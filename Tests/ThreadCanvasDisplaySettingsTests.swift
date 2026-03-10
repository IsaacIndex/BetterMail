import XCTest
@testable import BetterMail

@MainActor
final class ThreadCanvasDisplaySettingsTests: XCTestCase {
    func test_textScale_whenAssignedBelowMinimum_clampsToMinimum() {
        let settings = ThreadCanvasDisplaySettings()

        settings.textScale = 0.1

        XCTAssertEqual(settings.textScale,
                       ThreadCanvasDisplaySettings.minimumTextScale,
                       accuracy: 0.0001)
    }

    func test_textScale_whenAssignedAboveMaximum_clampsToMaximum() {
        let settings = ThreadCanvasDisplaySettings()

        settings.textScale = 5

        XCTAssertEqual(settings.textScale,
                       ThreadCanvasDisplaySettings.maximumTextScale,
                       accuracy: 0.0001)
    }

    func test_layoutMetricsFontScale_multipliesZoomScaleByTextScale() {
        let metrics = ThreadCanvasLayoutMetrics(zoom: 1.0,
                                                textScale: 1.25)

        XCTAssertEqual(metrics.fontScale, 1.25, accuracy: 0.0001)
    }

    func test_currentZoom_whenUpdatedBelowMinimum_clampsToMinimum() {
        let settings = ThreadCanvasDisplaySettings()

        settings.updateCurrentZoom(0.001)

        XCTAssertEqual(settings.currentZoom,
                       ThreadCanvasLayoutMetrics.minZoom,
                       accuracy: 0.0001)
    }

    func test_currentZoom_whenUpdatedAboveMaximum_clampsToMaximum() {
        let settings = ThreadCanvasDisplaySettings()

        settings.updateCurrentZoom(10)

        XCTAssertEqual(settings.currentZoom,
                       ThreadCanvasLayoutMetrics.maxZoom,
                       accuracy: 0.0001)
    }
}
