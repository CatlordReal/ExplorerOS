#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/tmp/explorer-android-sdk}}
gradle=${GRADLE_BIN:-/tmp/gradle-8.11.1/bin/gradle}
if [ ! -x "$gradle" ] || [ ! -d "$sdk/platforms/android-35" ]; then
  echo "Need Gradle 8.11.1 and Android SDK platform 35. See docs/GLASS.md." >&2
  exit 2
fi
export ANDROID_HOME="$sdk" ANDROID_SDK_ROOT="$sdk" JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}" GRADLE_USER_HOME="${GRADLE_USER_HOME:-/tmp/explorer-gradle-home}"
exec "$gradle" --no-daemon -p "$root" :app:assembleDebug
