import XCTest
@testable import UsageCore

final class TokenRefreshTests: XCTestCase {

    private let response: [String: Any] = [
        "access_token": "at-new",
        "refresh_token": "rt-new",
        "expires_in": 28800,
    ]

    func testRotationRewritesTheOAuthTripleAndNothingElse() throws {
        let root: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "at-old",
                "refreshToken": "rt-old",
                "expiresAt": 1_000,
                "subscriptionType": "max",
                "scopes": ["user:inference"],
            ],
            "mcpOAuth": ["something": "the CLI owns"],
        ]
        let now = Date()
        let rotated = try XCTUnwrap(TokenRefresher.applyRotation(
            into: root, response: response, previousRefreshToken: "rt-old", now: now))

        XCTAssertEqual(rotated.accessToken, "at-new")
        let oauth = try XCTUnwrap(rotated.root["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["accessToken"] as? String, "at-new")
        XCTAssertEqual(oauth["refreshToken"] as? String, "rt-new")
        XCTAssertEqual(oauth["expiresAt"] as? Int,
                       Int((now.timeIntervalSince1970 + 28800) * 1000))
        // Fields we don't own must survive — inside the oauth object and beside it.
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max")
        XCTAssertEqual(oauth["scopes"] as? [String], ["user:inference"])
        XCTAssertNotNil(rotated.root["mcpOAuth"])
    }

    func testResponseWithoutReplacementRefreshTokenKeepsOurs() throws {
        let rotated = try XCTUnwrap(TokenRefresher.applyRotation(
            into: ["claudeAiOauth": ["refreshToken": "rt-old"]],
            response: ["access_token": "at-new"],
            previousRefreshToken: "rt-old"))
        let oauth = try XCTUnwrap(rotated.root["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["refreshToken"] as? String, "rt-old")
    }

    func testResponseWithoutAccessTokenIsRejected() {
        XCTAssertNil(TokenRefresher.applyRotation(
            into: [:], response: ["refresh_token": "rt-new"],
            previousRefreshToken: "rt-old"))
    }

    func testWriteBackRoundTripsThroughTheRealFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".credentials.json")

        let rotated = try XCTUnwrap(TokenRefresher.applyRotation(
            into: ["claudeAiOauth": ["refreshToken": "rt-old"], "keep": true],
            response: response, previousRefreshToken: "rt-old"))
        TokenRefresher.writeBack(rotated.root, to: file)

        let readBack = try XCTUnwrap(TokenRefresher.readJSON(file))
        XCTAssertEqual((readBack["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String,
                       "at-new")
        XCTAssertEqual(readBack["keep"] as? Bool, true)
        // A credentials file must not be world-readable.
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o077, 0)
    }
}
