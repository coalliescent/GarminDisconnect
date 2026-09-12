// TestsMain.swift
//
// Single @main entry point for the unified test binary. Calls each suite's
// `runXxxTests()` function and aggregates pass/fail counts. Add new suites
// here.

import Foundation

@main
struct TestsMain {
    static func main() {
        var totalPassed = 0
        var totalFailed = 0

        let suites: [(name: String, run: () -> (passed: Int, failed: Int))] = [
            ("Database", runDatabaseTests),
            ("DateUtil", runDateUtilTests),
            ("ActivityGroup", runActivityGroupTests),
            ("ActivitySelection", runActivitySelectionTests),
        ]

        for suite in suites {
            print("\n=== \(suite.name) ===")
            let (p, f) = suite.run()
            print("\(suite.name): \(p) passed, \(f) failed")
            totalPassed += p
            totalFailed += f
        }

        print("\n=== TOTAL: \(totalPassed) passed, \(totalFailed) failed ===")
        if totalFailed > 0 { exit(1) }
    }
}
