//
//  SpiceHarvesterUITests.swift
//  SpiceHarvesterUITests
//
//  Created by David Mašín on 22.06.2025.
//

import XCTest

final class SpiceHarvesterUITests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingsTabsExposeExpectedContent() throws {
        let app = XCUIApplication()
        app.launch()

        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows["SpiceHarvester Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3), "Settings window should open with Cmd+,")

        assertSettingsTab("Výkon", exposes: ["Souběžnost", "Model a HTTP"], in: settingsWindow)
        assertSettingsTab("OCR", exposes: ["OCR backend"], in: settingsWindow)
        assertSettingsTab("Cache", exposes: ["Inferenční cache", "Vyčistit cache"], in: settingsWindow)
    }

    @MainActor
    private func assertSettingsTab(_ title: String, exposes expectedLabels: [String], in window: XCUIElement) {
        let button = window.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 2), "Settings tab '\(title)' should exist")
        button.click()

        for label in expectedLabels {
            let predicate = NSPredicate(format: "label == %@", label)
            let match = window.descendants(matching: .any).matching(predicate).firstMatch
            XCTAssertTrue(match.waitForExistence(timeout: 2), "Settings tab '\(title)' should expose '\(label)'")
        }
    }
}
