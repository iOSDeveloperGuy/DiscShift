import Foundation
import Darwin
import DiscDockCore

struct EngineFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct ChildIdentity {
    let pid: pid_t
    let seconds: UInt64
    let microseconds: UInt64
    init?(_ pid: pid_t) {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        self.pid = pid; seconds = info.pbi_start_tvsec; microseconds = info.pbi_start_tvusec
    }
    func signal(_ value: Int32) {
        guard let current = ChildIdentity(pid), current.seconds == seconds, current.microseconds == microseconds else { return }
        kill(pid, value)
    }
    static func descendants(of pid: pid_t) -> [ChildIdentity] {
        let bytes = proc_listchildpids(pid, nil, 0)
        guard bytes > 0 else { return [] }
        var children = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 32)
        let capacity = Int32(children.count * MemoryLayout<pid_t>.size)
        let result = children.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, capacity) }
        guard result > 0 else { return [] }
        return children.prefix(Int(result) / MemoryLayout<pid_t>.size).filter { $0 > 0 }.flatMap { child in
            descendants(of: child) + [ChildIdentity(child)].compactMap { $0 }
        }
    }
}

/// One serialized subprocess at a time. Both pipes drain concurrently, so verbose
/// diagnostics can never block encoding. Process arguments never pass through a shell.
@MainActor final class HandBrakeEngine {
    private var process: Process?
    private var cancellationRequested = false
    func cancel() {
        cancellationRequested = true
        guard let running = process, running.isRunning else { return }
        let children = ChildIdentity.descendants(of: running.processIdentifier)
        children.forEach { $0.signal(SIGTERM) }
        running.terminate()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            children.forEach { $0.signal(SIGKILL) }
            if running.isRunning { kill(running.processIdentifier, SIGKILL) }
        }
    }
    func run(executable: String, arguments: [String], libraryDirectory: String,
             event: @escaping @MainActor (HandBrakeEvent) -> Void,
             log: @escaping @MainActor (String) -> Void,
             captureOutput: (@MainActor (String) -> Void)? = nil,
             environmentOverrides: [String: String] = [:]) async throws {
        guard process == nil else { throw EngineFailure(message: "Another operation is still running.") }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw EngineFailure(message: "Choose a working HandBrakeCLI executable in Settings.")
        }
        cancellationRequested = false
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env.merge(environmentOverrides) { _, new in new }
        if !libraryDirectory.isEmpty { env["DYLD_FALLBACK_LIBRARY_PATH"] = libraryDirectory + ":/opt/homebrew/lib:/usr/local/lib:/usr/lib" }
        child.environment = env
        let output = Pipe(), errors = Pipe()
        child.standardOutput = output; child.standardError = errors
        child.standardInput = FileHandle.nullDevice
        process = child
        defer { process = nil }
        try child.run()
        // availableData blocks only detached reader tasks, never the main thread.
        let readOutput = Task.detached {
            var frames = JSONFrames()
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                if let captureOutput { await captureOutput(String(decoding: data, as: UTF8.self)) }
                for frame in frames.append(data) {
                    if let decoded = HandBrakeEvent.decode(frame) { await event(decoded) }
                }
            }
        }
        let readErrors = Task.detached {
            while true {
                let data = errors.fileHandleForReading.availableData
                if data.isEmpty { break }
                await log(String(decoding: data, as: UTF8.self))
            }
        }
        await Task.detached { child.waitUntilExit() }.value
        await readOutput.value; await readErrors.value
        if cancellationRequested { throw CancellationError() }
        if child.terminationStatus != 0 {
            throw EngineFailure(message: "HandBrake stopped (code \(child.terminationStatus)). Open Activity for details. Check the disc and your HandBrake/libdvdcss installation.")
        }
    }
}
