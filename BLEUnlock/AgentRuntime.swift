import Cocoa
import Carbon
import IOKit.pwr_mgt

// Agent Mode runtime: privacy shield, local-input guard, fail-closed watchdog
// and the local control socket. Policy lives in AgentMode.swift.

private let agentModeKey = "agentMode"
private let agentShieldStyleKey = "agentShieldStyle"
private let agentShieldTextKey = "agentShieldText"
private let agentIdleTimeoutKey = "agentIdleTimeout"
private let defaultAgentIdleTimeoutMinutes = 10
private let agentWatchdogArgument = "--agent-watchdog"
private let agentControlArgument = "agent"

/// What Agent Mode needs from the rest of the app.
protocol AgentModeHost: AnyObject {
    func agentLockScreen()
    func agentRunScript(_ event: String)
    func agentIsScreenLocked() -> Bool
    /// The monitored phone is nearby with stable unlock evidence.
    func agentPresenceHere() -> Bool
    func agentCanUnlockWithPassword() -> Bool
    /// Start typing the stored password into the lock screen.
    func agentUnlockWithPassword()
    func agentSettingsChanged()
}

// MARK: - Shield

/// Hides the desktop from people nearby while leaving screenshots intact:
/// either capture-excluded windows above everything, or zero display gamma
/// (applied after capture). Also keeps the displays awake.
final class AgentShield {
    private(set) var isShown = false
    private var style = AgentShieldStyle.overlay
    private var text = ""
    private var windows: [NSWindow] = []
    private var assertions: [IOPMAssertionID] = []
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?

    private static let background = NSColor(calibratedRed: 0.04, green: 0.06, blue: 0.12, alpha: 1)
    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, info in
        guard !flags.contains(.beginConfigurationFlag), let info = info else { return }
        let shield = Unmanaged<AgentShield>.fromOpaque(info).takeUnretainedValue()
        DispatchQueue.main.async { shield.maintain() }
    }

    func show(style: AgentShieldStyle, text: String) {
        if isShown && (style != self.style || text != self.text) {
            removeCover()
        }
        self.style = style
        self.text = text
        if !isShown {
            isShown = true
            holdPowerAssertions()
            CGDisplayRegisterReconfigurationCallback(Self.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.maintain()
            }
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.maintain()
            }
        }
        maintain()
    }

    /// Re-cover after display, Space or gamma changes. Cheap enough to poll.
    func maintain() {
        guard isShown else { return }
        switch style {
        case .overlay: maintainOverlay()
        case .blackout: maintainBlackout()
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        CGDisplayRemoveReconfigurationCallback(Self.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        [screenObserver].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver)
        [spaceObserver].compactMap { $0 }.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        screenObserver = nil
        spaceObserver = nil
        removeCover()
        releasePowerAssertions()
    }

    private func removeCover() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if style == .blackout {
            AgentGammaBackup.restore()
        }
    }

    private func maintainOverlay() {
        let screens = NSScreen.screens
        if windows.count != screens.count || zip(windows, screens).contains(where: { $0.frame != $1.frame }) {
            windows.forEach { $0.orderOut(nil) }
            windows = screens.map(makeOverlayWindow)
        }
        for window in windows where !window.isVisible || !window.isOnActiveSpace {
            window.orderFrontRegardless()
        }
    }

    private func makeOverlayWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.sharingType = .none
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.animationBehavior = .none
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = Self.background
        window.setFrame(screen.frame, display: false)

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 28, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -80),
        ])
        window.contentView = content
        window.orderFrontRegardless()
        return window
    }

    private func maintainBlackout() {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return }
        let zeros = [CGGammaValue](repeating: 0, count: 256)
        for display in displays.prefix(Int(count)) where !isBlack(display) {
            AgentGammaBackup.save(display)
            CGSetDisplayTransferByTable(display, 256, zeros, zeros, zeros)
        }
    }

    private func isBlack(_ display: CGDirectDisplayID) -> Bool {
        let capacity = CGDisplayGammaTableCapacity(display)
        guard capacity > 0 else { return false }
        var red = [CGGammaValue](repeating: 1, count: Int(capacity))
        var green = red, blue = red
        var sampleCount: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &sampleCount) == .success,
              sampleCount > 0 else { return false }
        let n = Int(sampleCount)
        return red.prefix(n).allSatisfy { $0 == 0 } && green.prefix(n).allSatisfy { $0 == 0 } && blue.prefix(n).allSatisfy { $0 == 0 }
    }

    private func holdPowerAssertions() {
        for type in [kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypePreventUserIdleSystemSleep] {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "BLEUnlock Agent Mode" as CFString, &id) == kIOReturnSuccess {
                assertions.append(id)
            }
        }
    }

    private func releasePowerAssertions() {
        assertions.forEach { IOPMAssertionRelease($0) }
        assertions.removeAll()
    }
}

/// Original gamma tables of blacked-out displays. macOS 26 keeps a gamma
/// table after the setting process exits and CGDisplayRestoreColorSyncSettings
/// does not undo it, so the tables are restored explicitly. They are also
/// written to disk so the watchdog, or the next launch, can restore them if
/// BLEUnlock dies while the displays are black.
enum AgentGammaBackup {
    private typealias Table = [String: [[Float]]]
    private static var tables: Table = [:]
    private static var url: URL { URL(fileURLWithPath: agentTemporaryPath("agent-gamma.plist")) }

    static func save(_ display: CGDirectDisplayID) {
        let key = String(display)
        guard tables[key] == nil else { return }
        let capacity = CGDisplayGammaTableCapacity(display)
        guard capacity > 0 else { return }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red, blue = red
        var samples: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &samples) == .success,
              samples > 0 else { return }
        let n = Int(samples)
        tables[key] = [Array(red.prefix(n)), Array(green.prefix(n)), Array(blue.prefix(n))]
        if let data = try? PropertyListSerialization.data(fromPropertyList: tables, format: .binary, options: 0) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Puts back the saved tables, from memory or from a leftover file.
    static func restore() {
        if tables.isEmpty, let data = try? Data(contentsOf: url),
           let saved = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Table {
            tables = saved
        }
        for (key, channels) in tables {
            guard let display = CGDirectDisplayID(key), channels.count == 3 else { continue }
            let n = UInt32(min(channels[0].count, channels[1].count, channels[2].count))
            CGSetDisplayTransferByTable(display, n, channels[0], channels[1], channels[2])
        }
        CGDisplayRestoreColorSyncSettings()
        tables.removeAll()
        try? FileManager.default.removeItem(at: url)
    }

    static var hasLeftover: Bool { FileManager.default.fileExists(atPath: url.path) }
}

// MARK: - Input guard

/// Listen-only event tap that tells local hardware input from synthetic input.
///
/// Hardware events, including Karabiner-Elements' virtual HID keyboard, carry
/// source PID 0; events posted with CGEventPost carry the poster's PID. Input
/// that apps deliver with CGEventPostToPid (Orca's background input) never
/// reaches this tap. BLEUnlock's own password and Escape events are ignored.
/// No IOHIDManager seize, so it coexists with Karabiner.
final class AgentInputGuard {
    var onHumanInput: (() -> Void)?
    var onAgentInput: (() -> Void)?
    private(set) var lastHumanInputAt = Date().timeIntervalSince1970
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var disabledSince: TimeInterval?
    private let ownPID = Int64(getpid())

    var isRunning: Bool { tap != nil }

    private static let eventMask: CGEventMask = {
        let types: [UInt32] = [
            CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue,
            CGEventType.mouseMoved.rawValue, CGEventType.scrollWheel.rawValue,
            CGEventType.leftMouseDown.rawValue, CGEventType.leftMouseUp.rawValue, CGEventType.leftMouseDragged.rawValue,
            CGEventType.rightMouseDown.rawValue, CGEventType.rightMouseUp.rawValue, CGEventType.rightMouseDragged.rawValue,
            CGEventType.otherMouseDown.rawValue, CGEventType.otherMouseUp.rawValue, CGEventType.otherMouseDragged.rawValue,
            CGEventType.tabletPointer.rawValue, CGEventType.tabletProximity.rawValue,
            // NSEvent gesture types (rotate, begin/end gesture, gesture, magnify,
            // swipe, smart magnify, pressure) so trackpad touches count too.
            18, 19, 20, 29, 30, 31, 32, 34,
        ]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1)) }
    }()

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        // Without Input Monitoring a listen-only tap may still be created yet
        // miss keyboard events; that must not count as a working guard.
        if #available(macOS 10.15, *), !CGPreflightListenEventAccess() {
            print("Agent Mode: Input Monitoring permission missing")
            return false
        }
        let callback: CGEventTapCallBack = { _, type, event, info in
            if let info = info {
                Unmanaged<AgentInputGuard>.fromOpaque(info).takeUnretainedValue().handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: Self.eventMask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            print("Agent Mode: cannot create input event tap")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.source = source
        disabledSince = nil
        lastHumanInputAt = Date().timeIntervalSince1970
        return true
    }

    func stop() {
        guard let tap = tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    /// False once the tap is missing or has stayed disabled for over a second.
    func checkHealth(now: TimeInterval) -> Bool {
        guard let tap = tap, CFMachPortIsValid(tap) else { return false }
        if CGEvent.tapIsEnabled(tap: tap) {
            disabledSince = nil
            return true
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) {
            disabledSince = nil
            return true
        }
        let since = disabledSince ?? now
        disabledSince = since
        return now - since < 1
    }

    /// Keyboard events are hidden from every event tap while an app holds
    /// Secure Event Input (password fields, some terminals).
    var secureInputActive: Bool { IsSecureEventInputEnabled() }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
        if pid == ownPID { return }
        if pid != 0 {
            onAgentInput?()
            return
        }
        lastHumanInputAt = Date().timeIntervalSince1970
        onHumanInput?()
    }
}

// MARK: - Watchdog

/// Parent side of the fail-closed watchdog: a copy of this executable started
/// with `--agent-watchdog` that locks the screen if this process exits or its
/// main thread stops sending heartbeats while a shield is up.
final class AgentWatchdog {
    var onUnexpectedExit: (() -> Void)?
    private var process: Process?
    private var writeFD: Int32 = -1
    private var armed = false

    var isAlive: Bool { process?.isRunning == true }

    func arm() -> Bool {
        if !isAlive && !spawn() { return false }
        armed = true
        return send("A")
    }

    func heartbeat() {
        if armed { _ = send("H") }
    }

    func disarm() {
        armed = false
        if isAlive { _ = send("D") }
    }

    private func spawn() -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = [agentWatchdogArgument]
        process.standardInput = pipe
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.process = nil
                if self.writeFD >= 0 { close(self.writeFD) }
                self.writeFD = -1
                if self.armed {
                    self.armed = false
                    self.onUnexpectedExit?()
                }
            }
        }
        do {
            try process.run()
        } catch {
            print("Agent Mode: cannot start watchdog: \(error)")
            return false
        }
        // Keep our own descriptor so a dead watchdog yields EPIPE, not SIGPIPE.
        writeFD = dup(pipe.fileHandleForWriting.fileDescriptor)
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        // Never let a stuck watchdog block the main thread.
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
        pipe.fileHandleForWriting.closeFile()
        self.process = process
        return writeFD >= 0
    }

    private func send(_ command: String) -> Bool {
        guard writeFD >= 0 else { return false }
        return command.utf8CString.withUnsafeBufferPointer { write(writeFD, $0.baseAddress, 1) == 1 }
    }
}

/// Watchdog process body. Never returns.
func runAgentWatchdog() -> Never {
    signal(SIGPIPE, SIG_IGN)
    // Leave the parent's process group so terminal signals aimed at a
    // debugging session do not take the watchdog down with it.
    setsid()
    let heartbeatTimeout = 2.0
    var armed = false
    var lastBeat = ProcessInfo.processInfo.systemUptime
    var buffer = [UInt8](repeating: 0, count: 256)
    func lock(_ reason: String) {
        print("Agent watchdog: \(reason); locking screen")
        _ = SACLockScreenImmediate()
        if AgentGammaBackup.hasLeftover {
            AgentGammaBackup.restore()
        }
    }
    while true {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, 200)
        let now = ProcessInfo.processInfo.systemUptime
        if ready > 0 {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count <= 0 {
                if armed { lock("BLEUnlock exited while shielded") }
                exit(0)
            }
            for byte in buffer.prefix(count) {
                switch byte {
                case UInt8(ascii: "A"): armed = true; lastBeat = now
                case UInt8(ascii: "H"): lastBeat = now
                case UInt8(ascii: "D"): armed = false
                default: break
                }
            }
        } else if ready < 0 && errno != EINTR {
            if armed { lock("watchdog pipe failed") }
            exit(1)
        }
        if armed && now - lastBeat > heartbeatTimeout {
            lock("BLEUnlock stopped responding while shielded")
            armed = false
        }
    }
}

// MARK: - Control socket

/// Per-user socket in the Darwin user temp directory (mode 0700, owned by the
/// user); connections from other UIDs are rejected as well.
func agentControlSocketPath() -> String {
    agentTemporaryPath("agent.sock")
}

/// A per-user, per-bundle file in the Darwin user temporary directory.
func agentTemporaryPath(_ suffix: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let directory = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0
        ? String(cString: buffer) : NSTemporaryDirectory()
    let name = (Bundle.main.bundleIdentifier ?? "BLEUnlock") + "." + suffix
    return (directory as NSString).appendingPathComponent(name)
}

private func makeSocketAddress(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}

final class AgentControlServer {
    /// Runs on the main thread; returns the JSON reply object.
    var handler: (([String]) -> [String: Any])?
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.github.Skyearn.BLEUnlock.agent-control")
    private let path = agentControlSocketPath()

    func start() {
        guard fd < 0, var address = makeSocketAddress(path) else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else {
            print("Agent Mode: cannot listen on \(path): \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 {
            close(fd)
            unlink(path)
        }
        fd = -1
    }

    private func acceptConnection() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        _ = fcntl(client, F_SETNOSIGPIPE, 1)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while data.count < 4096 && !data.contains(UInt8(ascii: "\n")) {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let args = line.split(separator: " ").map(String.init)
        var reply: [String: Any] = ["ok": false, "error": "no_handler"]
        DispatchQueue.main.sync {
            if let handler = self.handler { reply = handler(args) }
        }
        let json = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data("{}".utf8)
        (json + Data("\n".utf8)).withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
    }
}

/// `BLEUnlock agent <command>`: send one command to the running app.
/// Returns nil when the arguments are not a control command.
func runAgentCommandLineIfRequested(_ arguments: [String]) -> Int32? {
    if arguments.dropFirst().first == agentWatchdogArgument {
        runAgentWatchdog()
    }
    guard arguments.count >= 2, arguments[1] == agentControlArgument else { return nil }
    let command = arguments.dropFirst(2).joined(separator: " ")
    guard !command.isEmpty else {
        FileHandle.standardError.write(Data("""
        usage: BLEUnlock agent <command>
          status                 show Agent Mode state as JSON
          on | off               enable or disable Agent Mode
          shield                 cover the screens now; unlocks first if the screen is locked
          release                end the session (locks unless the phone is nearby)
          ping                   report agent activity (resets the idle timer)
          idle-timeout <min>     minutes without agent activity before locking; 0 = never
          style overlay|blackout choose the shield style

        """.utf8))
        return 64
    }
    let path = agentControlSocketPath()
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0, var address = makeSocketAddress(path) else { return 1 }
    defer { close(fd) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {
        FileHandle.standardError.write(Data("BLEUnlock is not running (no socket at \(path))\n".utf8))
        return 2
    }
    _ = (command + "\n").utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
    shutdown(fd, SHUT_WR)
    // The app answers on its main thread, which a modal dialog can block; do not hang the caller forever.
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        reply.append(contentsOf: buffer.prefix(count))
    }
    guard !reply.isEmpty else {
        FileHandle.standardError.write(Data("BLEUnlock did not respond within 10 seconds (is a dialog open?)\n".utf8))
        return 1
    }
    FileHandle.standardOutput.write(reply)
    let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
    return object?["ok"] as? Bool == true ? 0 : 1
}

// MARK: - Controller

/// Wires `AgentModeMachine` to the shield, guard, watchdog and control socket.
final class AgentModeController {
    weak var host: AgentModeHost?
    private let prefs: UserDefaults
    private var machine = AgentModeMachine()
    private let shield = AgentShield()
    private let inputGuard = AgentInputGuard()
    private let watchdog = AgentWatchdog()
    private let server = AgentControlServer()
    private var timer: Timer?
    private var teardownTimer: Timer?
    private var guardHealthy = false

    init(prefs: UserDefaults) {
        self.prefs = prefs
    }

    var enabled: Bool { machine.enabled }
    var isUnlocking: Bool { machine.phase == .unlocking }

    var style: AgentShieldStyle {
        prefs.string(forKey: agentShieldStyleKey).flatMap(AgentShieldStyle.init(rawValue:)) ?? .overlay
    }

    var idleTimeoutMinutes: Int {
        prefs.object(forKey: agentIdleTimeoutKey) == nil
            ? defaultAgentIdleTimeoutMinutes : max(0, prefs.integer(forKey: agentIdleTimeoutKey))
    }

    private var shieldText: String {
        if let text = prefs.string(forKey: agentShieldTextKey), !text.isEmpty { return text }
        return NSLocalizedString("agent_shield_text", value: "In use remotely — please don't touch",
                                 comment: "Single line shown on the Agent Mode privacy overlay")
    }

    private var now: TimeInterval { Date().timeIntervalSince1970 }

    func start() {
        if AgentGammaBackup.hasLeftover {
            AgentGammaBackup.restore()
        }
        machine.idleTimeout = TimeInterval(idleTimeoutMinutes * 60)
        inputGuard.onHumanInput = { [weak self] in
            guard let self = self, self.machine.isActive else { return }
            self.perform(self.machine.humanInput(now: self.now))
        }
        inputGuard.onAgentInput = { [weak self] in
            guard let self = self, self.machine.isActive else { return }
            self.machine.agentActivity(now: self.now)
        }
        watchdog.onUnexpectedExit = { [weak self] in
            guard let self = self else { return }
            print("Agent Mode: watchdog exited while shielded")
            self.perform(self.machine.failClosed(now: self.now))
        }
        server.handler = { [weak self] args in self?.handleCommand(args) ?? [:] }
        server.start()
        if prefs.bool(forKey: agentModeKey) {
            setEnabled(true)
        }
    }

    func shutdown() {
        if machine.isActive {
            // Quitting must not leave an unlocked, unshielded session behind.
            host?.agentLockScreen()
        }
        shield.hide()
        watchdog.disarm()
        inputGuard.stop()
        server.stop()
    }

    // MARK: Settings

    func setEnabled(_ on: Bool) {
        prefs.set(on, forKey: agentModeKey)
        let actions = machine.setEnabled(on, now: now, presenceHere: host?.agentPresenceHere() ?? false)
        if on {
            if #available(macOS 10.15, *), !CGPreflightListenEventAccess() {
                CGRequestListenEventAccess()
            }
            guardHealthy = inputGuard.start()
        }
        perform(actions)
        if !on && !machine.isActive {
            inputGuard.stop()
            guardHealthy = false
        }
        host?.agentSettingsChanged()
    }

    func setStyle(_ style: AgentShieldStyle) {
        prefs.set(style.rawValue, forKey: agentShieldStyleKey)
        if shield.isShown {
            shield.show(style: style, text: shieldText)
        }
        host?.agentSettingsChanged()
    }

    func setIdleTimeoutMinutes(_ minutes: Int) {
        prefs.set(max(0, minutes), forKey: agentIdleTimeoutKey)
        machine.idleTimeout = TimeInterval(idleTimeoutMinutes * 60)
        host?.agentSettingsChanged()
    }

    // MARK: Events from the app

    /// Called where the automatic lock would fire. Returns true when Agent
    /// Mode handled the departure, so the caller must skip its own lock.
    func handleAwayConfirmed() -> Bool {
        // A shield without a working input guard would only fail closed a
        // moment later; lock the ordinary way so scripts see `away`/`lost`.
        if machine.enabled && machine.phase == .idle {
            if !inputGuard.isRunning { guardHealthy = inputGuard.start() }
            if !inputGuard.isRunning || !guardHealthy { return false }
        }
        let actions = machine.awayConfirmed(now: now)
        if actions == [.legacyLock] { return false }
        perform(actions)
        return true
    }

    func presenceReturned() {
        perform(machine.presenceReturned(now: now))
    }

    func screenLocked() {
        perform(machine.screenLocked(now: now))
    }

    func screenUnlocked() {
        perform(machine.screenUnlocked(now: now, presenceHere: host?.agentPresenceHere() ?? false))
    }

    func systemWillSleep() {
        perform(machine.failClosed(now: now))
    }

    /// Seconds since the last local hardware input, when Agent Mode is
    /// tracking it; synthetic agent input must not count as the user being
    /// at the Mac. Nil means "use the system idle time" (Agent Mode off).
    func humanIdleSeconds() -> TimeInterval? {
        guard machine.enabled, inputGuard.isRunning else { return nil }
        return max(0, now - inputGuard.lastHumanInputAt)
    }

    // MARK: Actions

    private func perform(_ actions: [AgentAction]) {
        var failed = false
        let locking = actions.contains(.lock)
        for action in actions {
            switch action {
            case .legacyLock:
                break
            case .showShield:
                teardownTimer?.invalidate()
                teardownTimer = nil
                if !inputGuard.isRunning {
                    guardHealthy = inputGuard.start()
                }
                shield.show(style: style, text: shieldText)
                startTimer()
                if !guardHealthy || !watchdog.arm() {
                    print("Agent Mode: input guard or watchdog unavailable; failing closed")
                    failed = true
                }
            case .unlockWithPassword:
                host?.agentUnlockWithPassword()
            case .lock:
                host?.agentLockScreen()
            case .removeShield:
                if locking {
                    teardownAfterLock(deadline: now + 3)
                } else {
                    teardown()
                }
            case .script(let event):
                host?.agentRunScript(event)
            }
        }
        if failed {
            perform(machine.failClosed(now: now))
        }
        host?.agentSettingsChanged()
    }

    /// Keep the cover until the lock screen is actually up.
    private func teardownAfterLock(deadline: TimeInterval) {
        teardownTimer?.invalidate()
        teardownTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.host?.agentIsScreenLocked() == true || self.now >= deadline {
                timer.invalidate()
                self.teardownTimer = nil
                if !self.machine.isActive { self.teardown() }
            }
        }
        RunLoop.main.add(teardownTimer!, forMode: .common)
    }

    private func teardown() {
        shield.hide()
        watchdog.disarm()
        timer?.invalidate()
        timer = nil
        if !machine.enabled {
            inputGuard.stop()
            guardHealthy = false
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        guard machine.isActive else { return }
        watchdog.heartbeat()
        shield.maintain()
        guardHealthy = inputGuard.checkHealth(now: now)
        if !guardHealthy {
            print("Agent Mode: input guard stopped; failing closed")
            perform(machine.failClosed(now: now))
            return
        }
        let actions = machine.tick(now: now)
        if !actions.isEmpty { perform(actions) }
    }

    // MARK: Control commands

    private func handleCommand(_ args: [String]) -> [String: Any] {
        guard let command = args.first else { return ["ok": false, "error": "empty_command"] }
        let presenceHere = host?.agentPresenceHere() ?? false
        if machine.isActive { machine.agentActivity(now: now) }
        switch command {
        case "status":
            return status()
        case "ping":
            return ["ok": true, "phase": machine.phase.rawValue]
        case "on", "off":
            setEnabled(command == "on")
            return status()
        case "shield":
            let locked = host?.agentIsScreenLocked() ?? false
            if machine.enabled && !machine.isActive && locked && host?.agentCanUnlockWithPassword() != true {
                return ["ok": false, "error": "cannot_unlock_no_password_or_accessibility"]
            }
            switch machine.shieldCommand(now: now, screenLocked: locked) {
            case .success(let actions):
                perform(actions)
                return status()
            case .failure(let error):
                return ["ok": false, "error": error.rawValue]
            }
        case "release":
            perform(machine.releaseCommand(now: now, presenceHere: presenceHere))
            return status()
        case "idle-timeout":
            guard args.count == 2, let minutes = Int(args[1]), minutes >= 0 else {
                return ["ok": false, "error": "usage: idle-timeout <minutes>"]
            }
            setIdleTimeoutMinutes(minutes)
            return status()
        case "style":
            guard args.count == 2, let style = AgentShieldStyle(rawValue: args[1]) else {
                return ["ok": false, "error": "usage: style overlay|blackout"]
            }
            setStyle(style)
            return status()
        #if DEBUG
        // Development builds only: simulate phone transitions without BLE.
        case "simulate-away":
            guard host?.agentIsScreenLocked() == false else { return ["ok": false, "error": "screen_locked"] }
            if !handleAwayConfirmed() { return ["ok": false, "error": "agent_mode_off"] }
            return status()
        case "simulate-here":
            presenceReturned()
            return status()
        #endif
        default:
            return ["ok": false, "error": "unknown_command"]
        }
    }

    private func status() -> [String: Any] {
        let idleRemaining: Any = machine.phase == .shielded && machine.idleTimeout > 0
            ? max(0, Int(machine.idleTimeout - (now - machine.lastAgentActivity))) : NSNull()
        return [
            "ok": true,
            "agentMode": machine.enabled,
            "phase": machine.phase.rawValue,
            "shielded": shield.isShown,
            "presence": host?.agentPresenceHere() == true ? "here" : "away",
            "locked": host?.agentIsScreenLocked() ?? false,
            "guardHealthy": inputGuard.isRunning && guardHealthy,
            "secureInput": inputGuard.secureInputActive,
            "watchdog": watchdog.isAlive,
            "style": style.rawValue,
            "idleTimeoutMinutes": idleTimeoutMinutes,
            "idleRemainingSeconds": idleRemaining,
        ]
    }
}
