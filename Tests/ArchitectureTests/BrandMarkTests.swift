// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import XCTest

/// The app mark is the fleet's: the reflector at +28° and the three arcs
/// concentric on the feed horn, with the icon rendered from it by the
/// script in the tree.
final class BrandMarkTests: XCTestCase {

    private static let mark = "Resources/Dish.svg"
    private static let icon = "Resources/Dish.icns"
    private static let renderer = "scripts/render-icon.sh"

    func testTheMarkFacesItsSignal() throws {
        let svg = try RepoFiles.read(Self.mark)
        XCTAssertEqual(svg.components(separatedBy: "rotate(28 100 84)").count - 1, 2, "the halo cut and the reflector share the tilt")
        XCTAssertFalse(svg.contains("rotate(-28"), "the old aim, up and to the left")
        for arc in ["A 12 12 0 0 1 122.8 55.41", "A 26 26 0 0 1 135.16 48.84", "A 42 42 0 0 1 149.29 41.33"] {
            XCTAssertTrue(svg.contains(arc), "an arc concentric on the feed horn: \(arc)")
        }
        XCTAssertFalse(svg.contains("<metadata"), "the design tool's provenance block stays out")
    }

    func testTheIconIsRenderedFromTheMarkByTheScript() throws {
        let script = try RepoFiles.read(Self.renderer)
        XCTAssertTrue(script.contains("Resources/Dish.svg") && script.contains("Resources/Dish.icns"))
        XCTAssertTrue(script.contains("iconutil -c icns"))
        let attributes = try FileManager.default.attributesOfItem(atPath: RepoFiles.url(Self.icon).path)
        XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 100_000, "every slot up to 1024 px")
    }
}
