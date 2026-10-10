import Foundation
import Darwin

struct TerminalSessionError: LocalizedError {
    let errorDescription: String?

    init(_ operation: String, code: Int32 = errno) {
        errorDescription = "\(operation) failed: \(String(cString: strerror(code)))"
    }
}

/// Runs the user's shell attached to a pseudo-terminal and feeds its output into a `TerminalBuffer`.
final class TerminalSession {
    let buffer = TerminalBuffer(columns: 80, rows: 24)

    /// Called on the main thread whenever the screen contents change.
    var onUpdate: (() -> Void)?

    private(set) var isRunning = false

    private var masterFD: Int32 = -1
    private var slaveFD: Int32 = -1
    private var childPID: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?

    init() {
        buffer.onResponse = { [weak self] response in
            self?.send(response)
        }
    }

    func start() {
        guard !isRunning else { return }
        buffer.reset()
        do {
            try spawnShell()
            isRunning = true
        } catch {
            cleanUp()
            buffer.feed(Array("\(error.localizedDescription)\r\n".utf8))
        }
        onUpdate?()
    }

    func terminate() {
        guard isRunning else { return }
        let pid = childPID
        kill(pid, SIGHUP)
        cleanUp()
        isRunning = false
        // Reap the child off the main thread so it doesn't linger as a zombie.
        DispatchQueue.global().async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    func send(_ string: String) {
        guard masterFD >= 0 else { return }
        let bytes = Array(string.utf8)
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(masterFD, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    break
                }
                offset += written
            }
        }
    }

    func resize(columns: Int, rows: Int) {
        guard columns != buffer.columns || rows != buffer.rows else { return }
        buffer.resize(columns: columns, rows: rows)
        if masterFD >= 0 {
            updateWindowSize()
        }
        onUpdate?()
    }

    // MARK: - Process management

    private func spawnShell() throws {
        masterFD = posix_openpt(O_RDWR | O_NOCTTY)
        guard masterFD >= 0 else { throw TerminalSessionError("posix_openpt") }
        guard grantpt(masterFD) == 0 else { throw TerminalSessionError("grantpt") }
        guard unlockpt(masterFD) == 0 else { throw TerminalSessionError("unlockpt") }
        guard let namePointer = ptsname(masterFD) else { throw TerminalSessionError("ptsname") }
        let slavePath = String(cString: namePointer)

        // Keep our own handle on the slave side open so reads on the master
        // don't fail before the shell has opened it.
        slaveFD = open(slavePath, O_RDWR | O_NOCTTY)
        guard slaveFD >= 0 else { throw TerminalSessionError("open \(slavePath)") }
        _ = fcntl(masterFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slaveFD, F_SETFD, FD_CLOEXEC)
        updateWindowSize()

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["LANG"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        let shellPath = environment["SHELL"] ?? "/bin/zsh"
        let homePath = environment["HOME"] ?? NSHomeDirectory()

        // A leading "-" in argv[0] tells the shell to run as a login shell.
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("-" + (shellPath as NSString).lastPathComponent), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        // Opening the slave in the child (after it becomes a session leader)
        // makes it the shell's controlling terminal, so Ctrl-C, job control, etc. work.
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 2)
        // The non-_np variant only exists on macOS 26+; fall back for older systems.
        if #available(macOS 26.0, *) {
            posix_spawn_file_actions_addchdir(&fileActions, homePath)
        } else {
            posix_spawn_file_actions_addchdir_np(&fileActions, homePath)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        posix_spawnattr_setsigmask(&attributes, &signalMask)

        var pid: pid_t = 0
        let result = posix_spawn(&pid, shellPath, &fileActions, &attributes, argv, envp)
        guard result == 0 else { throw TerminalSessionError("posix_spawn \(shellPath)", code: result) }
        childPID = pid

        let fd = masterFD
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        readSource.setEventHandler { [weak self] in
            self?.readAvailableOutput()
        }
        readSource.setCancelHandler {
            close(fd)
        }
        readSource.resume()
        self.readSource = readSource

        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exitSource.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            self?.handleChildExit()
        }
        exitSource.resume()
        self.exitSource = exitSource
    }

    private func readAvailableOutput() {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let count = chunk.withUnsafeMutableBytes { read(masterFD, $0.baseAddress, $0.count) }
        guard count > 0 else { return }
        buffer.feed(Array(chunk[0..<count]))
        onUpdate?()
    }

    private func handleChildExit() {
        // Drain any output the shell wrote right before exiting.
        if masterFD >= 0 {
            _ = fcntl(masterFD, F_SETFL, O_NONBLOCK)
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = chunk.withUnsafeMutableBytes { read(masterFD, $0.baseAddress, $0.count) }
                guard count > 0 else { break }
                buffer.feed(Array(chunk[0..<count]))
            }
        }
        cleanUp()
        isRunning = false
        buffer.feed(Array("\r\n[Process exited — press any key to restart]".utf8))
        onUpdate?()
    }

    private func cleanUp() {
        exitSource?.cancel()
        exitSource = nil
        if let readSource {
            // The cancel handler closes the master file descriptor.
            readSource.cancel()
            self.readSource = nil
        } else if masterFD >= 0 {
            close(masterFD)
        }
        masterFD = -1
        if slaveFD >= 0 {
            close(slaveFD)
            slaveFD = -1
        }
    }

    private func updateWindowSize() {
        var size = winsize(
            ws_row: UInt16(clamping: buffer.rows),
            ws_col: UInt16(clamping: buffer.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }
}
