import XCTest
@testable import ApolloRuntime

final class LaunchRouteTests: XCTestCase {
    func testApolloLaunchesOnTasks() {
        XCTAssertEqual(SidebarRoute.launchDefault, .tasks)
    }
}
