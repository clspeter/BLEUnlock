#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc -swift-version 5 BLEUnlock/AgentMode.swift Tests/AgentMode/main.swift -o build/agent-mode-tests
build/agent-mode-tests
