import Foundation

struct AssertionFailure: Error, CustomStringConvertible {
    let message: String
    let file: String
    let line: UInt
    var description: String { "\(URL(fileURLWithPath: file).lastPathComponent):\(line): \(message)" }
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "Expectation failed", file: String = #filePath, line: UInt = #line) throws {
    if !condition {
        throw AssertionFailure(message: message(), file: file, line: line)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: @autoclosure () -> String = "", file: String = #filePath, line: UInt = #line) throws {
    if actual != expected {
        let extra = message().isEmpty ? "" : " (\(message()))"
        throw AssertionFailure(message: "Expected \(expected), got \(actual)\(extra)", file: file, line: line)
    }
}

func expectNil<T>(_ value: T?, file: String = #filePath, line: UInt = #line) throws {
    if let value {
        throw AssertionFailure(message: "Expected nil, got \(value)", file: file, line: line)
    }
}

func expectNotNil<T>(_ value: T?, _ message: @autoclosure () -> String = "Expected non-nil value", file: String = #filePath, line: UInt = #line) throws -> T {
    guard let value else {
        throw AssertionFailure(message: message(), file: file, line: line)
    }
    return value
}

struct TestCase: Sendable {
    let suite: String
    let name: String
    let run: @Sendable () async throws -> Void
}
