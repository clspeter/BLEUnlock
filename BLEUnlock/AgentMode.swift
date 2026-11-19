import Foundation

/// How the screen is hidden while an agent works and the user is away.
enum AgentShieldStyle: String, CaseIterable {
    /// Capture-excluded window above everything on every display.
    case overlay
    /// Display gamma set to zero; screenshots are unaffected.
    case blackout
}

/// Side effects requested by `AgentModeMachine`, executed in order by the app.
enum AgentAction: Equatable {
    /// Agent Mode is off: run the existing automatic lock path unchanged.
    case legacyLock
    case showShield
    /// Type the stored password into the lock screen (shield is already up).
    case unlockWithPassword
    case lock
    case removeShield
    case script(String)
}

enum AgentCommandError: String, Error {
    case disabled = "agent_mode_off"
}

/// Pure Agent Mode policy. The app feeds it presence, input and lock-state
/// events and executes the returned actions; nothing here touches the system.
///
/// A session starts when the phone is confirmed away (or on an explicit
/// `shield` command) and ends when the phone returns, a human touches the Mac,
/// the agent goes idle, the guard fails, or the user/agent releases it. Any end
/// while the user is not confirmed nearby locks the screen first.
struct AgentModeMachine {
    enum Phase: String {
        case idle
        /// Shield is up over the lock screen and the password is being typed.
        case unlocking
        case shielded
    }

    enum EndReason {
        case returned, command, intruded, idle, failed

        var script: String {
            switch self {
            case .intruded: return "agent-intruded"
            case .idle: return "agent-idle"
            case .returned, .command, .failed: return "agent-release"
            }
        }
    }

    static let unlockTimeout: TimeInterval = 15
    /// After an intrusion during `unlocking`, an unlock that still lands in
    /// this window is reverted with another lock.
    static let relockWindow: TimeInterval = 10

    var enabled = false
    /// Seconds without agent activity before a shielded session ends; 0 = never.
    var idleTimeout: TimeInterval = 600

    private(set) var phase: Phase = .idle
    private(set) var lastAgentActivity: TimeInterval = 0
    private(set) var unlockStartedAt: TimeInterval = 0
    private var relockUntil: TimeInterval = 0

    var isActive: Bool { phase != .idle }

    // MARK: Presence

    /// The automatic lock rules fired while the screen is unlocked.
    mutating func awayConfirmed(now: TimeInterval) -> [AgentAction] {
        guard enabled else { return [.legacyLock] }
        // Already covering the screen: repeated or flapping "away" must not
        // interrupt the agent with a lock.
        guard phase == .idle else { return [] }
        phase = .shielded
        lastAgentActivity = now
        return [.showShield, .script("agent-shield")]
    }

    /// The phone is back with stable unlock evidence.
    mutating func presenceReturned(now: TimeInterval) -> [AgentAction] {
        guard phase == .shielded else { return [] }
        return end(.returned, lock: false, now: now)
    }

    // MARK: Input

    mutating func humanInput(now: TimeInterval) -> [AgentAction] {
        guard phase != .idle else { return [] }
        return end(.intruded, lock: true, now: now)
    }

    /// Synthetic input from another process, or any control command.
    mutating func agentActivity(now: TimeInterval) {
        lastAgentActivity = max(lastAgentActivity, now)
    }

    // MARK: Lock state

    mutating func screenLocked(now: TimeInterval) -> [AgentAction] {
        // Someone (or our own lock) locked the session: nothing left to hide.
        guard phase == .shielded else { return [] }
        return end(.command, lock: false, now: now)
    }

    mutating func screenUnlocked(now: TimeInterval, presenceHere: Bool) -> [AgentAction] {
        switch phase {
        case .idle:
            guard now < relockUntil else { return [] }
            relockUntil = 0
            return [.lock]
        case .unlocking:
            phase = .shielded
            lastAgentActivity = now
            return presenceHere ? end(.returned, lock: false, now: now) : []
        case .shielded:
            return []
        }
    }

    mutating func tick(now: TimeInterval) -> [AgentAction] {
        switch phase {
        case .idle:
            return []
        case .unlocking:
            guard now - unlockStartedAt >= Self.unlockTimeout else { return [] }
            return end(.failed, lock: true, now: now)
        case .shielded:
            guard idleTimeout > 0, now - lastAgentActivity >= idleTimeout else { return [] }
            return end(.idle, lock: true, now: now)
        }
    }

    /// Input guard or watchdog unavailable, or the system is going to sleep.
    mutating func failClosed(now: TimeInterval) -> [AgentAction] {
        guard phase != .idle else { return [] }
        return end(.failed, lock: true, now: now)
    }

    // MARK: Commands

    mutating func shieldCommand(now: TimeInterval, screenLocked: Bool) -> Result<[AgentAction], AgentCommandError> {
        guard enabled else { return .failure(.disabled) }
        agentActivity(now: now)
        guard phase == .idle else { return .success([]) }
        lastAgentActivity = now
        relockUntil = 0
        if screenLocked {
            phase = .unlocking
            unlockStartedAt = now
            return .success([.showShield, .unlockWithPassword, .script("agent-shield")])
        }
        phase = .shielded
        return .success([.showShield, .script("agent-shield")])
    }

    mutating func releaseCommand(now: TimeInterval, presenceHere: Bool) -> [AgentAction] {
        guard phase != .idle else { return [] }
        return end(.command, lock: phase == .unlocking || !presenceHere, now: now)
    }

    mutating func setEnabled(_ on: Bool, now: TimeInterval, presenceHere: Bool) -> [AgentAction] {
        guard on != enabled else { return [] }
        let actions = on ? [] : releaseCommand(now: now, presenceHere: presenceHere)
        enabled = on
        return actions
    }

    private mutating func end(_ reason: EndReason, lock: Bool, now: TimeInterval) -> [AgentAction] {
        if phase == .unlocking {
            // Typed password may still be in flight; revert a late unlock.
            relockUntil = now + Self.relockWindow
        }
        phase = .idle
        return (lock ? [.lock] : []) + [.removeShield, .script(reason.script)]
    }
}
