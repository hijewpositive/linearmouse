// MIT License
// Copyright (c) 2021-2026 LinearMouse

@testable import LinearMouse
import XCTest

final class MappingActionKindTests: XCTestCase {
    func testPinchZoomKindAndDefault() {
        XCTAssertEqual(Scheme.Buttons.Mapping.Action(kind: .pinchZoom), .arg1(.pinchZoom(0.1)))
        XCTAssertEqual(Scheme.Buttons.Mapping.Action.arg1(.pinchZoom(-0.2)).kind, .pinchZoom)
    }

    func testPinchZoomConfigurationRoundTrip() throws {
        for value in [0.1, -0.25, 0] {
            let json = Data("{\"pinchZoom\":\(value)}".utf8)
            let action = try JSONDecoder().decode(Scheme.Buttons.Mapping.Action.self, from: json)
            XCTAssertEqual(action, .arg1(.pinchZoom(value)))
            let encoded = try JSONEncoder().encode(action)
            XCTAssertEqual(try JSONDecoder().decode(Scheme.Buttons.Mapping.Action.self, from: encoded), action)
        }
    }

    func testMappingActionKindReadsScrollKind() {
        let action = Scheme.Buttons.Mapping.Action.arg1(.mouseWheelScrollRight(.pixel(20)))

        XCTAssertEqual(action.kind, .mouseWheelScrollRight)
    }

    func testInitFromRunKindCreatesEmptyRunCommand() {
        XCTAssertEqual(Scheme.Buttons.Mapping.Action(kind: .run), .arg1(.run("")))
    }
}
