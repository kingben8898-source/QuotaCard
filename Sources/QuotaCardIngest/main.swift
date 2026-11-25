import Darwin
import Foundation
import QuotaCardCore

// Ignore SIGPIPE so fast-exiting chained statusLine commands never terminate this helper
signal(SIGPIPE, SIG_IGN)

func parseArguments(_ args: [String]) -> (provider: String, quotaDir: URL, debugSchema: Bool, printStatusLine: Bool) {
    var provider = "antigravity"
    var quotaDir = StateStore.defaultDirectory()
    var debugSchema = false
    var printStatusLine = false

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--provider":
            if i + 1 < args.count {
                provider = args[i + 1]
                i += 1
            }
        case "--quota-dir":
            if i + 1 < args.count {
                let expanded = (args[i + 1] as NSString).expandingTildeInPath
                quotaDir = URL(fileURLWithPath: expanded, isDirectory: true)
                i += 1
            }
        case "--debug-schema":
            debugSchema = true
        case "--print-statusline":
            printStatusLine = true
        default:
            break
        }
        i += 1
    }
    return (provider, quotaDir, debugSchema, printStatusLine)
}

func runChainedCommand(_ command: String, stdinData: Data) -> Data? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-c", command]

    let inPipe = Pipe()
    let outPipe = Pipe()
    proc.standardInput = inPipe
    proc.standardOutput = outPipe
    proc.standardError = FileHandle.nullDevice

    do {
        try proc.run()
        // Write stdin asynchronously and drain stdout concurrently BEFORE waitUntilExit()
        // to prevent SIGPIPE crashes and >64KB pipe deadlocks.
        let writeHandle = inPipe.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            if !stdinData.isEmpty {
                try? writeHandle.write(contentsOf: stdinData)
            }
            try? writeHandle.close()
        }
        let output = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return output
    } catch {
        return nil
    }
}

let config = parseArguments(Array(CommandLine.arguments.dropFirst()))
let rawInput = FileHandle.standardInput.readDataToEndOfFile()
let now = Date()

let store = StateStore(baseDirectory: config.quotaDir)
var parsedUpdate: ProviderUpdate?

let debugMarkerURL = config.quotaDir.appendingPathComponent("debug-schema-enabled")
let shouldLogSchema = config.debugSchema || FileManager.default.fileExists(atPath: debugMarkerURL.path)

if !rawInput.isEmpty {
    if shouldLogSchema, let summary = PayloadParser.redactSchemaSummary(from: rawInput) {
        let logURL = config.quotaDir.appendingPathComponent("debug-schema.log")
        try? FileManager.default.createDirectory(at: config.quotaDir, withIntermediateDirectories: true)
        let line = "[\(ISO8601DateFormatter().string(from: now))] provider=\(config.provider) schema=\(summary)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    if let update = PayloadParser.parse(providerId: config.provider, data: rawInput, now: now) {
        parsedUpdate = update
        _ = try? store.applyUpdate(update)
    }
}

// Forward to any chained pre-existing statusLine command first; otherwise print concise fallback statusline
let configurator = CLIConfigurator(quotaCardDir: config.quotaDir)
if let managed = ManagedCLI(rawValue: config.provider.lowercased()),
   let chained = configurator.chainedCommand(for: managed),
   let chainedOut = runChainedCommand(chained, stdinData: rawInput) {
    try? FileHandle.standardOutput.write(contentsOf: chainedOut)
} else if config.printStatusLine, let update = parsedUpdate {
    let line = PayloadParser.formatFallbackStatusLine(from: update, now: now) + "\n"
    try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
}

exit(0)
