#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
xcodegen_bin="$project_dir/.tools/xcodegen/xcodegen/bin/xcodegen"

if [[ ! -x "$xcodegen_bin" ]]; then
  print -u2 "缺少本地 XcodeGen：$xcodegen_bin"
  print -u2 "请重新下载官方 xcodegen.zip 并解压到 .tools/xcodegen。"
  exit 1
fi

cd "$project_dir"
"$xcodegen_bin" generate
plutil -lint Config/iOS-Info.plist Config/Watch-Info.plist \
  Config/iOS.entitlements Config/Watch.entitlements

if [[ -d /Applications/Xcode.app ]]; then
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild -project SensorRead.xcodeproj -list
else
  print "工程已生成。安装完整 Xcode 后即可进行编译和真机签名。"
fi

