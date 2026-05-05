// GarminDumpRunner.swift
//
// Subprocess wrapper for the `garmin-dump` Python CLI. The viewer never talks
// to MTP/FIT directly — that's all garmin-dump's job. We just shell out to
// `garmin-dump pull` and observe its results.
//
// Phase 1 (this file): synchronous block-and-wait. We launch garmin-dump
// pull, capture stdout/stderr, parse the final summary line with a regex, and
// return a result. Progress is implied by the spinner in the UI; we don't try
// to stream per-file events because garmin-dump doesn't yet emit JSON.
//
// Phase 2 (future, in garmin-dump): add `--json` to `pull` so this wrapper can
// parse NDJSON events for live progress. Non-blocking dependency — Phase 1
// ships first and is good enough for the v1 sync UX.
//
// Runtime resolution: we do NOT invoke a venv-installed `garmin-dump` script,
// because venv shebangs bake in absolute paths that break the moment the
// bundle is moved to a different machine (or even just a different user's
// home). Instead, build.sh pip-installs garmin-dump and its pure-Python deps
// into `<bundle>/Contents/Resources/pylib`, and we spawn:
//
//     python3 -m garmin_dump <subcommand>
//
// with PYTHONPATH=<pylib>. This keeps the .app self-contained (only a system
// python3 >= 3.12 is required on the target machine). Resolution order:
//   1. UserDefaults["GarminDisconnect.garminDumpPath"] override — a direct
//      path to a garmin-dump executable. Bypasses the bundle entirely; useful
//      for debugging with a custom build. No PYTHONPATH injection.
//   2. Bundle-embedded payload at <bundle>/Contents/Resources/pylib, invoked
//      via a system python3 (checked in order: /opt/homebrew/bin/python3,
//      /usr/local/bin/python3, /usr/bin/python3).
// First match wins.

import Foundation

public enum GarminDumpError: Error, CustomStringConvertible {
    /// No runnable garmin-dump could be located. The reason string explains
    /// which specific piece is missing (python3 on the target machine, the
    /// in-bundle pylib payload, etc.) so the alert can be actionable.
    case runtimeNotFound(reason: String)
    case launchFailed(String)
    case nonZeroExit(code: Int32, stderr: String)

    public var description: String {
        switch self {
        case .runtimeNotFound(let reason):
            return "garmin-dump runtime unavailable: \(reason)"
        case .launchFailed(let msg):
            return "couldn't launch garmin-dump: \(msg)"
        case .nonZeroExit(let code, let stderr):
            return "garmin-dump exited \(code): \(stderr.prefix(500))"
        }
    }
}

/// How to invoke garmin-dump. Either a direct binary (UserDefaults override)
/// or a python3 + module + PYTHONPATH triple (the bundle-embedded payload).
/// Callers never construct these — use `GarminDumpRunner.findRuntime()`.
public struct GarminDumpRuntime {
    let launchPath: String
    let prefixArgs: [String]
    let extraEnv: [String: String]
}

/// Result of a single `garmin-dump pull` invocation. Phase 1 fills only the
/// fields we can scrape from text output; Phase 2 will populate the rest from
/// NDJSON.
public struct PullResult {
    public let success: Bool
    public let filesDownloaded: Int
    public let bytesDownloaded: Int
    public let errors: Int
    public let durationSeconds: Double
    public let rawStdout: String
    public let rawStderr: String
}

public final class GarminDumpRunner {

    private static let userDefaultsKey = "GarminDisconnect.garminDumpPath"
    private static let pythonCandidates = [
        "/opt/homebrew/bin/python3",  // Homebrew Apple Silicon
        "/usr/local/bin/python3",     // Homebrew Intel
        "/usr/bin/python3",           // CLT-provided
    ]

    /// Cached runtime for this process. Resolution is stable for the lifetime
    /// of the app, so we only do it once.
    private static var cachedRuntime: GarminDumpRuntime?
    /// Last resolution failure reason, if any. Captured so the caller's error
    /// message can be specific (missing python3 vs missing pylib).
    private static var lastResolutionReason: String = "not yet attempted"

    /// Resolve how to invoke garmin-dump. Returns nil if no workable runtime
    /// is available — see `lastResolutionReason` for why.
    public static func findRuntime() -> GarminDumpRuntime? {
        if let cached = cachedRuntime { return cached }

        // 1. UserDefaults escape hatch: direct path to a garmin-dump binary.
        //    No prefix args, no PYTHONPATH — the caller is responsible for
        //    making sure that binary can find its own deps.
        if let override = UserDefaults.standard.string(forKey: userDefaultsKey),
           !override.isEmpty {
            if FileManager.default.isExecutableFile(atPath: override) {
                let rt = GarminDumpRuntime(launchPath: override, prefixArgs: [], extraEnv: [:])
                cachedRuntime = rt
                return rt
            }
            lastResolutionReason =
                "UserDefaults path '\(override)' is not executable; clear it in Preferences."
            return nil
        }

        // 2. Bundle-embedded pylib + system python3. See header comment.
        let pylib = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/pylib")
            .path
        var isDir: ObjCBool = false
        let pkgPath = pylib + "/garmin_dump"
        let pylibOK = FileManager.default.fileExists(atPath: pkgPath, isDirectory: &isDir)
            && isDir.boolValue
        if !pylibOK {
            lastResolutionReason =
                "bundle payload missing at \(pkgPath). Rebuild the app with `make`."
            return nil
        }
        guard let python = pythonCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            lastResolutionReason =
                "no python3 found in " + pythonCandidates.joined(separator: ", ")
                + ". Install Xcode Command Line Tools (`xcode-select --install`) or Homebrew Python."
            return nil
        }

        let rt = GarminDumpRuntime(
            launchPath: python,
            prefixArgs: ["-m", "garmin_dump"],
            extraEnv: ["PYTHONPATH": pylib]
        )
        cachedRuntime = rt
        return rt
    }

    /// Run `garmin-dump status` and return its raw text output. Used to peek
    /// at what a pull would do without doing it. Currently parsed via regex.
    public static func runStatus() throws -> String {
        guard let runtime = findRuntime() else {
            throw GarminDumpError.runtimeNotFound(reason: lastResolutionReason)
        }
        let result = try execute(runtime: runtime, arguments: ["status"], timeout: 30)
        if result.exitCode != 0 {
            throw GarminDumpError.nonZeroExit(code: result.exitCode, stderr: result.stderr)
        }
        return result.stdout
    }

    /// Run `garmin-dump pull` and return a parsed result. Throws on non-zero
    /// exit so the caller can surface the failure; the combined stdout+stderr
    /// is attached to the thrown `nonZeroExit` so it can be interpreted into
    /// a user-facing message (see the `GarminDumpError.alert*` helpers).
    public static func runPull() throws -> PullResult {
        guard let runtime = findRuntime() else {
            throw GarminDumpError.runtimeNotFound(reason: lastResolutionReason)
        }
        let started = Date()
        let result = try execute(runtime: runtime, arguments: ["pull"], timeout: 600)
        let elapsed = Date().timeIntervalSince(started)
        let combined = result.stdout + "\n" + result.stderr
        if result.exitCode != 0 {
            throw GarminDumpError.nonZeroExit(code: result.exitCode, stderr: combined)
        }
        let parsed = parsePullSummary(combined)
        return PullResult(
            success: true,
            filesDownloaded: parsed.files,
            bytesDownloaded: parsed.bytes,
            errors: parsed.errors,
            durationSeconds: elapsed,
            rawStdout: result.stdout,
            rawStderr: result.stderr
        )
    }

    // MARK: - Private subprocess plumbing

    private struct ExecResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func execute(
        runtime: GarminDumpRuntime,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> ExecResult {
        let task = Process()
        task.launchPath = runtime.launchPath
        task.arguments = runtime.prefixArgs + arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        // GUI-launched apps on macOS get a minimal PATH that typically omits
        // /opt/homebrew/bin, which is where mtp-detect lives. Augment so
        // garmin-dump's libmtp subprocesses are findable.
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        let augmentedPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = existing + ":" + augmentedPath
        } else {
            env["PATH"] = augmentedPath
        }
        for (k, v) in runtime.extraEnv { env[k] = v }
        task.environment = env

        do {
            try task.run()
        } catch {
            throw GarminDumpError.launchFailed(error.localizedDescription)
        }

        // Wait with timeout. Process doesn't have a built-in timeout in Swift,
        // so we poll on a background queue.
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning {
            if Date() > deadline {
                task.terminate()
                throw GarminDumpError.nonZeroExit(
                    code: -1,
                    stderr: "garmin-dump timed out after \(Int(timeout))s"
                )
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return ExecResult(
            exitCode: task.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    // MARK: - Output parsers

    /// Best-effort regex scrape of garmin-dump's pull summary. The CLI prints
    /// something like:
    ///
    ///   Pull complete  device=3509067685
    ///     files seen:       318
    ///     files downloaded: 12
    ///     bytes downloaded: 12.50 MB
    ///     remote deletions: 0
    ///     ingested:         3 activities, 1 sleeps, 240 samples
    ///     parser errors:    0
    ///     download errors:  0
    ///
    /// We pull `files downloaded`, `bytes downloaded` (converting MB→bytes),
    /// and `download errors`. Robust against missing lines (treat as 0).
    private static func parsePullSummary(_ text: String) -> (files: Int, bytes: Int, errors: Int) {
        func extract(_ pattern: String, in haystack: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                return nil
            }
            let range = NSRange(location: 0, length: haystack.utf16.count)
            guard let match = regex.firstMatch(in: haystack, options: [], range: range),
                  match.numberOfRanges >= 2 else {
                return nil
            }
            let matchRange = match.range(at: 1)
            guard let swiftRange = Range(matchRange, in: haystack) else { return nil }
            return String(haystack[swiftRange])
        }

        var files = 0
        if let s = extract(#"files\s+downloaded:\s+(\d+)"#, in: text) {
            files = Int(s) ?? 0
        }
        var errors = 0
        if let s = extract(#"download\s+errors:\s+(\d+)"#, in: text) {
            errors = Int(s) ?? 0
        }
        var bytes = 0
        if let s = extract(#"bytes\s+downloaded:\s+([0-9.]+)\s+MB"#, in: text),
           let mb = Double(s) {
            bytes = Int(mb * 1024 * 1024)
        }
        return (files: files, bytes: bytes, errors: errors)
    }
}

// MARK: - Alert-friendly error messages
//
// The Python CLI prints its failure modes to stdout as "error: <msg>" (rich
// strips its bbcode when not writing to a TTY, so we get plain text). The
// cases here cover the known user-facing failures:
//
//   • libmtp missing from PATH            ToolchainError
//   • no Garmin device detected           DeviceNotFoundError
//   • device held by another process      DeviceBusyError
//   • GarminDevice.xml couldn't be read   GarminXmlError
//   • Swift-side timeout                  synthesized nonZeroExit(-1, "timed out...")
//   • runtime unavailable                 GarminDumpError.runtimeNotFound
//   • subprocess launch failed            GarminDumpError.launchFailed
//
// Anything else falls back to surfacing the first `error:` / `fatal:` line
// from the captured output, or the raw tail if no such line exists.
extension GarminDumpError {

    /// Short title for an NSAlert presenting this error.
    public var alertTitle: String {
        switch self {
        case .runtimeNotFound:
            return "garmin-dump runtime unavailable"
        case .launchFailed:
            return "Couldn't launch garmin-dump"
        case .nonZeroExit(_, let output):
            if Self.looksLikeLibmtpMissing(output) { return "libmtp is not installed" }
            if output.contains("no Garmin MTP device detected") { return "No Garmin watch detected" }
            if output.contains("appears to be held by another process") { return "The watch is busy" }
            if output.contains("timed out after") { return "garmin-dump timed out" }
            if output.contains("GarminDevice.xml") { return "Couldn't read watch identity" }
            return "Sync failed"
        }
    }

    /// Detailed body for an NSAlert presenting this error. Tailored copy for
    /// common, actionable failures; falls back to surfacing the subprocess's
    /// own error text for everything else.
    public var alertMessage: String {
        switch self {
        case .runtimeNotFound(let reason):
            return "GarminDisconnect couldn't find a way to run garmin-dump.\n\n"
                 + "Details: \(reason)"
        case .launchFailed(let msg):
            return "The garmin-dump process failed to start:\n\n\(msg)"
        case .nonZeroExit(let code, let output):
            return Self.interpret(output: output, exitCode: code)
        }
    }

    private static func interpret(output: String, exitCode: Int32) -> String {
        if looksLikeLibmtpMissing(output) {
            return "Install libmtp from Homebrew:\n\n    brew install libmtp\n\n"
                 + "…then click Sync again."
        }
        if output.contains("no Garmin MTP device detected") {
            return "garmin-dump didn't find a Garmin watch over USB. Check that:\n"
                 + "  • The watch is plugged in with a data cable (not charge-only)\n"
                 + "  • The watch is awake and unlocked\n"
                 + "  • No other app (Garmin Express, Image Capture, Android File Transfer) "
                 + "is currently holding the device"
        }
        if output.contains("appears to be held by another process") {
            let holders = firstMatch(#"held by another process:\s*([^\n]+)"#, in: output)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let who = (holders?.isEmpty == false) ? "Another app (\(holders!)) is" : "Another app is"
            return "\(who) currently talking to the watch. Quit it (cmd-Q) and try again. "
                 + "Don't use `kill -9` — let the other app exit cleanly so it releases the device."
        }
        if output.contains("timed out after") {
            return "garmin-dump didn't finish within the allotted time (10 minutes). "
                 + "The watch may have gone to sleep or been unplugged mid-transfer. "
                 + "Wake the watch and try again."
        }
        if output.contains("GarminDevice.xml") {
            return "garmin-dump couldn't read the watch's identity file (GarminDevice.xml). "
                 + "This is usually a transient USB glitch — unplug and re-plug the watch, "
                 + "then try again."
        }
        if let line = firstMatch(#"(?m)^(?:error|fatal):\s*(.+)$"#, in: output) {
            return line
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "garmin-dump exited with code \(exitCode) and produced no output."
        }
        return "garmin-dump exited with code \(exitCode):\n\n\(String(trimmed.suffix(500)))"
    }

    private static func looksLikeLibmtpMissing(_ output: String) -> Bool {
        guard output.contains("not found on PATH") else { return false }
        return output.contains("mtp-detect")
            || output.contains("mtp-getfile")
            || output.contains("mtp-folders")
            || output.contains("libmtp")
    }

    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let match = regex.firstMatch(in: s, range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
