#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
derived_dir=/tmp/SensorReadDerivedDemo

phone_id=$(xcrun simctl list devices available | sed -nE '/iPhone 17 Pro \(/s/.*\(([0-9A-F-]{36})\).*/\1/p' | head -n 1)
watch_id=$(xcrun simctl list devices available | sed -nE '/Apple Watch Series 11 \(46mm\)/s/.*\(([0-9A-F-]{36})\).*/\1/p' | head -n 1)

if [[ -z "$phone_id" || -z "$watch_id" ]]; then
  print -u2 "未找到 iPhone 17 Pro 或 Apple Watch Series 11 (46mm) 模拟器。"
  exit 1
fi

cd "$project_dir"
Tools/prepare_project.sh

xcrun simctl pair "$watch_id" "$phone_id" 2>/dev/null || true
xcrun simctl boot "$phone_id" 2>/dev/null || true
xcrun simctl boot "$watch_id" 2>/dev/null || true
xcrun simctl bootstatus "$phone_id" -b
xcrun simctl bootstatus "$watch_id" -b

xcodebuild -project SensorRead.xcodeproj \
  -scheme SensorRead \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$phone_id" \
  -derivedDataPath "$derived_dir" \
  build

xcrun simctl terminate "$phone_id" com.sensorread.ios 2>/dev/null || true
xcrun simctl uninstall "$phone_id" com.sensorread.ios 2>/dev/null || true
xcrun simctl install "$phone_id" "$derived_dir/Build/Products/Debug-iphonesimulator/SensorRead.app"
xcrun simctl install "$watch_id" "$derived_dir/Build/Products/Debug-watchsimulator/SensorReadWatch.app"
xcrun simctl launch "$watch_id" com.sensorread.ios.watchkitapp
xcrun simctl launch "$phone_id" com.sensorread.ios --auto-start-demo
open -a Simulator

print "Sensor Read 已在配对的 iPhone 和 Apple Watch 模拟器中启动。"
