import XCTest
@testable import ApolloRuntime

final class LunarSplashPolicyTests: XCTestCase {
    func testNeverLeavesBeforeTheThreeSecondMinimum() {
        XCTAssertEqual(LunarSplashPolicy.decide(elapsed: 2.99, introComplete: true, dataReady: true), .hold)
        XCTAssertEqual(LunarSplashPolicy.decide(elapsed: 3.0, introComplete: true, dataReady: true), .exit)
    }

    func testWaitsForTheIntroToFinish() {
        XCTAssertEqual(LunarSplashPolicy.decide(elapsed: 4, introComplete: false, dataReady: true), .hold)
    }

    func testHoldsWhileDataIsLoading() {
        XCTAssertEqual(LunarSplashPolicy.decide(elapsed: 6, introComplete: true, dataReady: false), .hold)
    }

    func testMaximumWaitWinsOverEverything() {
        let cap = LunarSplashPolicy.maximumWait
        XCTAssertEqual(LunarSplashPolicy.decide(elapsed: cap, introComplete: false, dataReady: false), .exit)
    }

    func testDataReadiness() {
        XCTAssertTrue(LunarSplashPolicy.isDataReady(hasTasks: true, isSyncing: true))
        XCTAssertTrue(LunarSplashPolicy.isDataReady(hasTasks: false, isSyncing: false))
        XCTAssertFalse(LunarSplashPolicy.isDataReady(hasTasks: false, isSyncing: true))
    }
}
