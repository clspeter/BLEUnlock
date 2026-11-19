import Cocoa

// Agent Mode helpers (`agent <command>` client, `--agent-watchdog`) run
// without starting the app; everything else is the normal menu bar app.
if let status = runAgentCommandLineIfRequested(CommandLine.arguments) {
    exit(status)
}
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
