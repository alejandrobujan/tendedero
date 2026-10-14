import XCTest
@testable import Tendedero

final class HoverActivationTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let band = CGRect(x: 0, y: 868, width: 1440, height: 32)
    private let left = CGRect(x: 0, y: 868, width: 620, height: 32)
    private let right = CGRect(x: 820, y: 868, width: 620, height: 32)

    func testNotchTargetsExcludeNotchAndMenus() {
        let regions = HoverActivation.regions(menuBar: band, screen: screen, safeAreaTop: 32,
                                              left: left, right: right)
        XCTAssertEqual(regions, [CGRect(x: 540, y: 868, width: 80, height: 32),
                                 CGRect(x: 820, y: 868, width: 80, height: 32)])
        for point in [CGPoint(x: 720, y: 880), CGPoint(x: 50, y: 880), CGPoint(x: 1380, y: 880)] {
            XCTAssertFalse(regions.contains { $0.contains(point) })
        }
    }

    func testNoNotchAndInvalidGeometryUseCentre() {
        let expected = [CGRect(x: 640, y: 868, width: 160, height: 32)]
        for (top, l, r) in [(CGFloat(0), Optional(left), Optional(right)),
                            (32, nil, nil), (32, left, nil),
                            (32, right, left), (32, left, left),
                            (32, CGRect.zero, right)] {
            XCTAssertEqual(HoverActivation.regions(menuBar: band, screen: screen, safeAreaTop: top,
                                                   left: l, right: r), expected)
        }
    }

    func testOffsetDisplayAndAutoHiddenMenuBar() {
        let offset = CGVector(dx: -1440, dy: 900)
        let move: (CGRect) -> CGRect = { $0.offsetBy(dx: offset.dx, dy: offset.dy) }
        // The menu-bar band is supplied by AppDelegate even when hidden.
        let regions = HoverActivation.regions(menuBar: move(band), screen: move(screen), safeAreaTop: 32,
                                              left: move(left), right: move(right))
        XCTAssertEqual(regions.map { $0.offsetBy(dx: -offset.dx, dy: -offset.dy) },
                       HoverActivation.regions(menuBar: band, screen: screen, safeAreaTop: 32,
                                               left: left, right: right))
    }

    func testTargetsAreClippedToScreenAndMenuBar() {
        let narrow = CGRect(x: 0, y: 0, width: 100, height: 100)
        let oversizedBand = CGRect(x: -10, y: 80, width: 120, height: 40)
        XCTAssertEqual(HoverActivation.regions(menuBar: oversizedBand, screen: narrow, safeAreaTop: 0,
                                              left: nil, right: nil),
                       [CGRect(x: 0, y: 80, width: 100, height: 20)])
        XCTAssertTrue(HoverActivation.regions(menuBar: .zero, screen: narrow, safeAreaTop: 0,
                                              left: nil, right: nil).isEmpty)
        XCTAssertEqual(HoverActivation.regions(menuBar: oversizedBand, screen: narrow, safeAreaTop: 20,
                                              left: CGRect(x: 0, y: 80, width: 20, height: 20),
                                              right: CGRect(x: 80, y: 80, width: 20, height: 20)),
                       [CGRect(x: 0, y: 80, width: 20, height: 20),
                        CGRect(x: 80, y: 80, width: 20, height: 20)])
    }

    func testDwellRequiresContinuousStayAndResetsAcrossTargetsAndDisplays() {
        var dwell = HoverActivation.Dwell()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let other = band.offsetBy(dx: 500, dy: 0)
        func ready(_ region: CGRect, _ display: UInt32, _ seconds: Double) -> Bool {
            dwell.isReady(in: region, display: display, at: start.addingTimeInterval(seconds), delay: 0.25)
        }
        XCTAssertFalse(ready(band, 1, 0))
        XCTAssertFalse(ready(band, 1, 0.24))
        XCTAssertTrue(ready(band, 1, 0.25))
        XCTAssertFalse(ready(other, 1, 0.26))
        XCTAssertTrue(ready(other, 1, 0.51))
        XCTAssertFalse(ready(other, 2, 0.52))
        XCTAssertTrue(ready(other, 2, 0.77))
        dwell.reset()
        XCTAssertFalse(ready(other, 2, 1))
        XCTAssertTrue(ready(other, 2, 1.25))
    }
}
