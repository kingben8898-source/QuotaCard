import Foundation
@testable import QuotaCardCore

enum LocalIngestServerTests {
    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quotacard-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var all: [TestCase] {
        [
            TestCase(suite: "LocalIngestServerTests", name: "tokenFileCreatedWith0600Permissions") {
                let dir = try makeTempDir()
                defer { try? FileManager.default.removeItem(at: dir) }
                let tokenURL = dir.appendingPathComponent("auth-token")
                let store = StateStore(baseDirectory: dir)
                let server = LocalIngestServer(store: store, port: 0, tokenFileURL: tokenURL)

                try expectEqual(server.authToken.count, 64)
                let attrs = try FileManager.default.attributesOfItem(atPath: tokenURL.path)
                let perms = try expectNotNil(attrs[.posixPermissions] as? NSNumber).intValue
                try expectEqual(perms & 0o777, 0o600)
            },
            TestCase(suite: "LocalIngestServerTests", name: "healthEndpointReturns200WithoutLeakingQuota") {
                let dir = try makeTempDir()
                defer { try? FileManager.default.removeItem(at: dir) }
                let store = StateStore(baseDirectory: dir)
                let server = LocalIngestServer(store: store, port: 0, tokenFileURL: dir.appendingPathComponent("auth-token"))

                let raw = "GET /v1/health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
                let resp = server.handleRawHTTPRequest(Data(raw.utf8))
                try expectEqual(resp.statusCode, 200)
                let bodyText = String(data: resp.body, encoding: .utf8) ?? ""
                try expect(bodyText.contains("\"status\":\"ok\""))
            },
            TestCase(suite: "LocalIngestServerTests", name: "postProviderRejectsMissingOrInvalidBearerToken") {
                let dir = try makeTempDir()
                defer { try? FileManager.default.removeItem(at: dir) }
                let store = StateStore(baseDirectory: dir)
                let server = LocalIngestServer(store: store, port: 0, tokenFileURL: dir.appendingPathComponent("auth-token"))

                let payload = #"{"pools":[{"id":"g","name":"Gemini Web","fiveHour":{"remainingPercent":90}}]}"#
                let rawMissing = "POST /v1/providers/gemini-web HTTP/1.1\r\nContent-Length: \(payload.utf8.count)\r\n\r\n\(payload)"
                let respMissing = server.handleRawHTTPRequest(Data(rawMissing.utf8))
                try expectEqual(respMissing.statusCode, 401)

                let rawWrong = "POST /v1/providers/gemini-web HTTP/1.1\r\nAuthorization: Bearer wrongtoken\r\nContent-Length: \(payload.utf8.count)\r\n\r\n\(payload)"
                let respWrong = server.handleRawHTTPRequest(Data(rawWrong.utf8))
                try expectEqual(respWrong.statusCode, 401)
                try expectEqual(store.load().providers.count, 0)
            },
            TestCase(suite: "LocalIngestServerTests", name: "postProviderWithValidTokenMergesIntoStateStore") {
                let dir = try makeTempDir()
                defer { try? FileManager.default.removeItem(at: dir) }
                let store = StateStore(baseDirectory: dir)
                let server = LocalIngestServer(store: store, port: 0, tokenFileURL: dir.appendingPathComponent("auth-token"))

                let payload = #"{"displayName":"Gemini Web","shortName":"Gemini","pools":[{"id":"g","name":"Gemini Web","fiveHour":{"remainingPercent":85,"resetAt":"2026-11-25T15:00:00Z"}}]}"#
                let raw = "POST /v1/providers/gemini-web HTTP/1.1\r\nAuthorization: Bearer \(server.authToken)\r\nContent-Length: \(payload.utf8.count)\r\n\r\n\(payload)"
                let resp = server.handleRawHTTPRequest(Data(raw.utf8))
                try expectEqual(resp.statusCode, 200)

                let loaded = store.load()
                let gemini = try expectNotNil(loaded.providers["gemini-web"])
                try expectEqual(gemini.displayName, "Gemini Web")
                try expectEqual(gemini.pools.first?.fiveHour?.remainingPercent, 85.0)
            },
            TestCase(suite: "LocalIngestServerTests", name: "postProviderWithInvalidJSONReturns400") {
                let dir = try makeTempDir()
                defer { try? FileManager.default.removeItem(at: dir) }
                let store = StateStore(baseDirectory: dir)
                let server = LocalIngestServer(store: store, port: 0, tokenFileURL: dir.appendingPathComponent("auth-token"))

                let payload = "{not valid json"
                let raw = "POST /v1/providers/gemini-web HTTP/1.1\r\nAuthorization: Bearer \(server.authToken)\r\nContent-Length: \(payload.utf8.count)\r\n\r\n\(payload)"
                let resp = server.handleRawHTTPRequest(Data(raw.utf8))
                try expectEqual(resp.statusCode, 400)
            }
        ]
    }
}
