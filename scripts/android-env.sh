#!/usr/bin/env bash
# Source this file to select the task's existing local Android toolchain.
if [[ -z "${JAVA_HOME:-}" && -d "$HOME/Library/Java/JavaVirtualMachines/sfn-temurin-17.jdk/Contents/Home" ]]; then
	export JAVA_HOME="$HOME/Library/Java/JavaVirtualMachines/sfn-temurin-17.jdk/Contents/Home"
fi
if [[ -z "${ANDROID_HOME:-}" && -d "$HOME/Library/Android/sdk" ]]; then
	export ANDROID_HOME="$HOME/Library/Android/sdk"
fi
if [[ -n "${ANDROID_HOME:-}" ]]; then
	export ANDROID_SDK_ROOT="$ANDROID_HOME"
	export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
fi
if [[ -n "${JAVA_HOME:-}" ]]; then
	export PATH="$JAVA_HOME/bin:$PATH"
fi
