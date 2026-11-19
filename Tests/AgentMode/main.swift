import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError(message) }
}
func enabledMachine(idleTimeout: TimeInterval = 600) -> AgentModeMachine {
    var machine = AgentModeMachine()
    machine.idleTimeout = idleTimeout
    _ = machine.setEnabled(true, now: 0, presenceHere: true)
    return machine
}

// Agent Mode off: every input defers to the existing lock path and nothing else happens.
var off = AgentModeMachine()
check(off.awayConfirmed(now: 1) == [.legacyLock], "Off must keep the existing automatic lock")
check(off.awayConfirmed(now: 2) == [.legacyLock], "Off must lock on every confirmed departure")
check(off.presenceReturned(now: 3).isEmpty, "Off must not react to presence")
check(off.humanInput(now: 4).isEmpty, "Off must ignore local input")
check(off.screenUnlocked(now: 5, presenceHere: false).isEmpty, "Off must not relock manual unlocks")
check(off.screenLocked(now: 6).isEmpty, "Off must ignore lock notifications")
check(off.tick(now: 10_000).isEmpty, "Off must never idle-lock")
check(off.failClosed(now: 7).isEmpty, "Off has nothing to fail closed")
check(off.releaseCommand(now: 8, presenceHere: false).isEmpty, "Off has no session to release")
if case .failure(.disabled) = off.shieldCommand(now: 9, screenLocked: false) {} else {
    check(false, "Shield command must be refused while Agent Mode is off")
}
check(off.phase == .idle, "Off must never leave idle")

// Away with Agent Mode on shields instead of locking; flapping never adds a lock.
var away = enabledMachine()
check(away.awayConfirmed(now: 10) == [.showShield, .script("agent-shield")], "Departure must shield, not lock")
check(away.phase == .shielded, "Session must be shielded")
check(away.awayConfirmed(now: 11).isEmpty, "Repeated departure must not lock the agent out")
check(away.presenceReturned(now: 12) == [.removeShield, .script("agent-release")], "Return must drop the shield without locking")
check(away.phase == .idle, "Return ends the session")
check(away.awayConfirmed(now: 13) == [.showShield, .script("agent-shield")], "Leaving again re-shields without a lock")
check(away.presenceReturned(now: 14).count == 2 && away.awayConfirmed(now: 15).first == .showShield,
      "Away/here/away flaps must never emit .lock")

// Local human input while shielded locks first, then removes the shield.
var touched = enabledMachine()
_ = touched.awayConfirmed(now: 0)
check(touched.humanInput(now: 1) == [.lock, .removeShield, .script("agent-intruded")], "Touch must lock before unshielding")
check(touched.humanInput(now: 2).isEmpty, "A second touch after the lock must be a no-op")
check(touched.screenUnlocked(now: 3, presenceHere: false).isEmpty, "A later human unlock of an unlocked-then-locked session is not reverted")
check(touched.enabled, "Intrusion must not turn Agent Mode off")

// Idle exit locks after the configured silence; agent activity and pings postpone it.
var idle = enabledMachine(idleTimeout: 600)
_ = idle.awayConfirmed(now: 0)
check(idle.tick(now: 599).isEmpty, "Idle exit must wait for the full timeout")
idle.agentActivity(now: 500)
check(idle.tick(now: 1099).isEmpty, "Agent activity must restart the idle timer")
check(idle.tick(now: 1100) == [.lock, .removeShield, .script("agent-idle")], "Idle agent must end with a lock")
check(idle.enabled && idle.phase == .idle, "Idle exit keeps Agent Mode on but ends the session")
var never = enabledMachine(idleTimeout: 0)
_ = never.awayConfirmed(now: 0)
check(never.tick(now: 1_000_000).isEmpty, "Idle timeout 0 must never end the session")
var pinged = enabledMachine(idleTimeout: 60)
_ = pinged.awayConfirmed(now: 0)
if case .success(let actions) = pinged.shieldCommand(now: 50, screenLocked: false) {
    check(actions.isEmpty, "Shield while shielded only refreshes activity")
}
check(pinged.tick(now: 100).isEmpty, "A command while shielded counts as agent activity")

// Shielding an already locked screen: shield first, then type the password.
var wake = enabledMachine()
if case .success(let actions) = wake.shieldCommand(now: 0, screenLocked: true) {
    check(actions == [.showShield, .unlockWithPassword, .script("agent-shield")], "Locked shield must cover before unlocking")
} else {
    check(false, "Shield command must succeed when enabled")
}
check(wake.phase == .unlocking, "Locked shield waits for the unlock")
check(wake.screenUnlocked(now: 2, presenceHere: false).isEmpty, "Unlock completes into a shielded session")
check(wake.phase == .shielded, "Unlocked agent session must be shielded")
check(wake.screenLocked(now: 3) == [.removeShield, .script("agent-release")], "External lock ends the session without another lock")

var wakeNearby = enabledMachine()
_ = wakeNearby.shieldCommand(now: 0, screenLocked: true)
check(wakeNearby.screenUnlocked(now: 1, presenceHere: true) == [.removeShield, .script("agent-release")],
      "Unlocking with the user nearby needs no shield")

var wakeStuck = enabledMachine()
_ = wakeStuck.shieldCommand(now: 0, screenLocked: true)
check(wakeStuck.tick(now: 14).isEmpty, "Unlock gets time to complete")
check(wakeStuck.tick(now: 15) == [.lock, .removeShield, .script("agent-release")], "A stuck unlock fails closed")
check(wakeStuck.screenUnlocked(now: 16, presenceHere: false) == [.lock], "A late unlock after giving up is reverted")

var wakeIntruded = enabledMachine()
_ = wakeIntruded.shieldCommand(now: 0, screenLocked: true)
check(wakeIntruded.humanInput(now: 1) == [.lock, .removeShield, .script("agent-intruded")], "Touch during unlock aborts")
check(wakeIntruded.screenUnlocked(now: 2, presenceHere: false) == [.lock], "Password already typed must not leave the Mac open")
check(wakeIntruded.screenUnlocked(now: 3, presenceHere: false).isEmpty, "Relock happens only once")
var wakeIntrudedLate = enabledMachine()
_ = wakeIntrudedLate.shieldCommand(now: 0, screenLocked: true)
_ = wakeIntrudedLate.humanInput(now: 1)
check(wakeIntrudedLate.screenUnlocked(now: 1 + AgentModeMachine.relockWindow, presenceHere: false).isEmpty,
      "A human unlock after the relock window is left alone")

// Release and disable lock unless the user is confirmed nearby.
var releaseAway = enabledMachine()
_ = releaseAway.awayConfirmed(now: 0)
check(releaseAway.releaseCommand(now: 1, presenceHere: false) == [.lock, .removeShield, .script("agent-release")],
      "Releasing while away must lock")
var releaseHere = enabledMachine()
_ = releaseHere.shieldCommand(now: 0, screenLocked: false)
check(releaseHere.releaseCommand(now: 1, presenceHere: true) == [.removeShield, .script("agent-release")],
      "Releasing with the user nearby just unshields")
var disable = enabledMachine()
_ = disable.awayConfirmed(now: 0)
check(disable.setEnabled(false, now: 1, presenceHere: false) == [.lock, .removeShield, .script("agent-release")],
      "Turning Agent Mode off while away must lock")
check(!disable.enabled && disable.awayConfirmed(now: 2) == [.legacyLock], "After disabling, departure locks as before")

// Guard failure or sleep fails closed.
var failed = enabledMachine()
_ = failed.awayConfirmed(now: 0)
check(failed.failClosed(now: 1) == [.lock, .removeShield, .script("agent-release")], "Guard failure must lock")
check(failed.failClosed(now: 2).isEmpty, "Fail-closed is idempotent")

print("Agent Mode tests passed: \(checks) checks")
