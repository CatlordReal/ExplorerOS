#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="${TMPDIR:-/tmp}/explorer-glass-core-$$"
trap 'rm -rf "$out"' EXIT INT TERM
mkdir -p "$out"
"${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}/bin/javac" -d "$out" $(rg --files "$root/app/src/main/java/com/exploreros/glass/core") "$root/app/src/main/java/com/exploreros/glass/hfp/VoicePolicy.java" "$root/app/src/main/java/com/exploreros/glass/TcpBridge.java" "$root/app/src/main/java/com/exploreros/glass/ble/GattOperationQueue.java" "$root/app/src/main/java/com/exploreros/glass/ancs/AncsActionGate.java" "$root/app/src/main/java/com/exploreros/glass/ancs/AncsAttributeParser.java" "$root/app/src/main/java/com/exploreros/glass/ancs/AncsNotifications.java" "$root/app/src/main/java/com/exploreros/glass/ams/AmsState.java" "$root/app/src/main/java/com/exploreros/glass/ui/GestureDecoder.java" "$root/app/src/main/java/com/exploreros/glass/integration/IntegrationPolicy.java" "$root/src/test/java/com/exploreros/glass/CoreTest.java" "$root/src/test/java/com/exploreros/glass/TransportTest.java"
"${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}/bin/java" -cp "$out" com.exploreros.glass.CoreTest "$(dirname "$root")/fixtures/protocol-v1.json"
"${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}/bin/java" -cp "$out" com.exploreros.glass.TransportTest
