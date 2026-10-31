//
//  DolbyVisionTests.swift
//  ColorimetryModelTests
//
//  The Inspector's Dolby Vision row (0.9.1): profile → text. Values as the DOVI record states them
//  (`dv_profile`, `dv_bl_signal_compatibility_id`); 8.4 level 7 is the iPhone clip IMG_5070.MOV, profile 5
//  the HDR Samples streaming masters.
//

import XCTest
@testable import ColorimetryModel

final class DolbyVisionTests: XCTestCase {

    private func text(_ profile: Int, compat: Int, level: Int = 6, bl: Bool = true, el: Bool = false) -> (String, Bool) {
        let t = DolbyVisionConfig(profile: profile, level: level, enhancementLayerPresent: el,
                                  baseLayerPresent: bl, compatibilityID: compat).inspectorText
        return (t.text, t.isWarning)
    }

    func testProfile8BaseLayers() {
        XCTAssertTrue(text(8, compat: 1) == ("Profile 8.1 (level 6) · HDR10 base layer shown; DV metadata not applied", false))
        XCTAssertTrue(text(8, compat: 2) == ("Profile 8.2 (level 6) · SDR base layer shown; DV metadata not applied", false))
        XCTAssertTrue(text(8, compat: 4, level: 7) == ("Profile 8.4 (level 7) · HLG base layer shown; DV metadata not applied", false))
    }

    func testProfile7() {
        XCTAssertTrue(text(7, compat: 6, el: true)
                      == ("Profile 7 (level 6) · HDR10 base layer shown; enhancement layer and DV metadata not applied", false))
    }

    /// Profile 5's base layer is IPTPQc2 (compatibility 0): no standard decoder can show it.
    func testProfile5WarnsNoCompatibleBaseLayer() {
        XCTAssertTrue(text(5, compat: 0, level: 3) == ("Profile 5 (level 3) · no compatible base layer; picture will not display correctly", true))
    }

    /// Any profile whose base layer is missing or declares no compatible signal gets the same warning.
    func testAnyProfileWithoutCompatibleBaseLayerWarns() {
        XCTAssertTrue(text(8, compat: 0).1)
        XCTAssertTrue(text(8, compat: 1, bl: false).1)
        XCTAssertEqual(text(4, compat: 1, bl: false).0, "Profile 4 (level 6) · no compatible base layer; picture will not display correctly")
    }

    /// The player window's banner: profile 5 and any profile without a compatible base layer, never a valid 8.x or 7.
    func testBanner() {
        func banner(_ profile: Int, compat: Int, bl: Bool = true) -> String? {
            DolbyVisionConfig(profile: profile, level: 6, baseLayerPresent: bl, compatibilityID: compat).bannerText
        }
        XCTAssertEqual(banner(5, compat: 0),
                       "Dolby Vision Profile 5: this file has no compatible base layer, so Manifold can't display it correctly.")
        XCTAssertNotNil(banner(5, compat: 1))
        XCTAssertNotNil(banner(4, compat: 1, bl: false))
        XCTAssertNil(banner(8, compat: 1))
        XCTAssertNil(banner(8, compat: 2))
        XCTAssertNil(banner(8, compat: 4))
        XCTAssertNil(banner(7, compat: 6))
    }

    /// Everything else: profile, compatibility and level, and "not applied".
    func testOtherProfilesShowProfileAndLevel() {
        XCTAssertTrue(text(9, compat: 2, level: 5) == ("Profile 9.2 (level 5) · not applied", false))
        XCTAssertTrue(text(10, compat: 1, level: 9) == ("Profile 10.1 (level 9) · not applied", false))
        XCTAssertTrue(text(8, compat: 6, level: 3) == ("Profile 8.6 (level 3) · not applied", false))
    }
}
