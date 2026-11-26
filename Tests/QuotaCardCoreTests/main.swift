import Foundation

let args = Array(CommandLine.arguments.dropFirst())
var filter: String?
if let idx = args.firstIndex(of: "--filter"), idx + 1 < args.count {
    filter = args[idx + 1]
}

let suites: [TestCase] = ModelsAndFormattingTests.all + StateStoreTests.all + PayloadParserTests.all + CLIConfiguratorTests.all + LocalIngestServerTests.all + IngestCLIIntegrationTests.all + WindowGeometryTests.all + TranscriptTokenScannerTests.all + RefreshPolicyTests.all + CodexSessionScannerTests.all
let selected = suites.filter { tc in
    guard let filter else { return true }
    return "\(tc.suite).\(tc.name)".localizedCaseInsensitiveContains(filter)
}

let semaphore = DispatchSemaphore(value: 0)
final class ExitCodeBox: @unchecked Sendable { var code: Int32 = 0 }
let exitBox = ExitCodeBox()

Task.detached {
    var passed = 0
    var failed = 0
    for tc in selected {
        do {
            try await tc.run()
            passed += 1
            print("PASS  \(tc.suite).\(tc.name)")
        } catch {
            failed += 1
            print("FAIL  \(tc.suite).\(tc.name): \(error)")
        }
    }
    print("Summary: \(passed) passed, \(failed) failed (total \(selected.count))")
    exitBox.code = failed == 0 ? 0 : 1
    semaphore.signal()
}

semaphore.wait()
exit(exitBox.code)
