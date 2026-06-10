import Foundation

@discardableResult
func runShell(_ path: String, args: [String], timeout: TimeInterval = 5.0) -> String {
    runShellEx(path, args: args, timeout: timeout).output
}

@discardableResult
func runShellEx(_ path: String, args: [String], timeout: TimeInterval = 5.0) -> (output: String, exitCode: Int32) {
    guard FileManager.default.isExecutableFile(atPath: path) else { return ("", -1) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardInput = FileHandle.nullDevice
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe

    // Drain pipes while the process runs. Reading only after exit deadlocks
    // once the child fills the 64 KB pipe buffer (lsof easily exceeds it).
    var outData = Data()
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        drained.signal()
    }
    DispatchQueue.global(qos: .utility).async {
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
    }

    let exited = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in exited.signal() }

    do {
        try p.run()
    } catch {
        return ("", -1)
    }

    if exited.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        if exited.wait(timeout: .now() + 0.5) == .timedOut {
            kill(p.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 0.5)
        }
        return ("", -1)
    }

    _ = drained.wait(timeout: .now() + 1.0)
    return (String(data: outData, encoding: .utf8) ?? "", p.terminationStatus)
}
