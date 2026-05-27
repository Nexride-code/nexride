#!/usr/bin/env bash
# ADB UI login helper for NexRide rider/driver on emulator.
set -euo pipefail

PKG="${1:?package com.nexride.rider or com.nexride.driver}"
EMAIL="${2:?email}"
PASS="${3:?password}"

adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 4

clear_field() {
  adb shell input tap "$1" "$2"
  sleep 0.3
  for _ in $(seq 1 48); do adb shell input keyevent 67 >/dev/null 2>&1; done
  sleep 0.2
}

# Email field center (layout varies slightly after relaunch)
clear_field 540 612
adb shell input text "$EMAIL"
sleep 0.5

# Password field
clear_field 540 790
adb shell input text "$PASS"
sleep 0.5

# Login button
adb shell input tap 540 1030
sleep 6

echo "login_tap_done pkg=$PKG email=$EMAIL"
