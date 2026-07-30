import Foundation
import XCTest
@testable import vz_macos

final class AuthenticationWatchdogTests: XCTestCase {
    func testDeadlineExpiresBeforeHelloAuthentication() {
        let connectedAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(
            authenticationDeadlineExpired(
                since: connectedAt,
                now: connectedAt.addingTimeInterval(14.9)
            )
        )
        XCTAssertTrue(
            authenticationDeadlineExpired(
                since: connectedAt,
                now: connectedAt.addingTimeInterval(15.1)
            )
        )
    }

    func testAuthenticatedRpcRefreshesDeadlineBaseline() {
        let authenticatedRpcAt = Date(timeIntervalSince1970: 2_000)

        XCTAssertFalse(
            authenticationDeadlineExpired(
                since: authenticatedRpcAt,
                now: authenticatedRpcAt.addingTimeInterval(5)
            )
        )
    }
}
