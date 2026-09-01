#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
destination="${1:-${project_dir}/dist}"
app_name="Local iOS Agent"
bundle_dir="${destination}/${app_name}.app"
contents_dir="${bundle_dir}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"
bootstrap_resources_dir="${resources_dir}/ProjectBootstrap"

cd "${project_dir}"
swift build -c release

binary_path="$(swift build -c release --show-bin-path)/LocalIOSAgent"

mkdir -p "${macos_dir}" "${bootstrap_resources_dir}"
cp "${binary_path}" "${macos_dir}/LocalIOSAgent"
cp "${project_dir}/Templates/iOS-AGENTS.md" "${bootstrap_resources_dir}/iOS-AGENTS.md"
cp "${project_dir}/Templates/XcodeBuildMCP-SKILL.md" "${bootstrap_resources_dir}/XcodeBuildMCP-SKILL.md"

plist_path="${contents_dir}/Info.plist"
/usr/libexec/PlistBuddy -c "Clear dict" "${plist_path}" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string en" "${plist_path}"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${app_name}" "${plist_path}"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string LocalIOSAgent" "${plist_path}"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string local.codex.LocalIOSAgent" "${plist_path}"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "${plist_path}"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string ${app_name}" "${plist_path}"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "${plist_path}"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0" "${plist_path}"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "${plist_path}"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "${plist_path}"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "${plist_path}"
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "${plist_path}"
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "${plist_path}"
/usr/libexec/PlistBuddy -c "Add :NSLocalNetworkUsageDescription string Local Ollama and OpenCode services are accessed only on this Mac." "${plist_path}"

chmod +x "${macos_dir}/LocalIOSAgent"
codesign --force --deep --sign - "${bundle_dir}"

echo "${bundle_dir}"
