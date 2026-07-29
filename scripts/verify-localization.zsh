#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h}"
localizable="$repo_root/EqualizerAUM1/Resources/Localizable.xcstrings"
info_plist="$repo_root/EqualizerAUM1/Resources/InfoPlist.xcstrings"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

xcrun xcstringstool compile --output-directory "$temp_dir/localizable" "$localizable"
xcrun xcstringstool compile --output-directory "$temp_dir/info-plist" "$info_plist"

python3 - "$localizable" "$info_plist" "$repo_root/EqualizerAUM1" <<'PY'
import json
import re
import sys
from pathlib import Path

localizable_path, info_path, source_root = map(Path, sys.argv[1:])
catalog = json.loads(localizable_path.read_text())
info_catalog = json.loads(info_path.read_text())
for path, data in ((localizable_path, catalog), (info_path, info_catalog)):
    if data.get("sourceLanguage") != "en":
        raise SystemExit(f"{path}: sourceLanguage must be en")

def units(node):
    result = [node["stringUnit"]] if "stringUnit" in node else []
    for variation in node.get("variations", {}).values():
        for value in variation.values():
            result.extend(units(value))
    return result

printf_pattern = re.compile(r'%(?:\d+\$)?(?:@|[-+0-9.#]*?(?:hh|h|ll|l|L|z|t|j)?[diuoxXfFeEgGaAcsp])')

def placeholders(value):
    return [re.sub(r"^%\d+\$", "%", item) for item in printf_pattern.findall(value)]

strings = catalog.get("strings", {})
for key, entry in strings.items():
    localizations = entry.get("localizations", {})
    zh_units = units(localizations.get("zh-Hans", {}))
    if not zh_units or any(unit.get("state") != "translated" or not unit.get("value") for unit in zh_units):
        raise SystemExit(f"missing translated zh-Hans value for {key!r}")
    expected = placeholders(key)
    for locale, localization in localizations.items():
        if any(placeholders(unit["value"]) != expected for unit in units(localization)):
            raise SystemExit(f"{locale} placeholder mismatch for {key!r}")

info = info_catalog.get("strings", {})
if set(info) != {"NSAudioCaptureUsageDescription"}:
    raise SystemExit("InfoPlist.xcstrings must contain only NSAudioCaptureUsageDescription")
for locale in ("en", "zh-Hans"):
    if not units(info["NSAudioCaptureUsageDescription"].get("localizations", {}).get(locale, {})):
        raise SystemExit(f"missing InfoPlist localization for {locale}")
plural = strings.get("%lld points", {}).get("localizations", {})
if set(plural.get("en", {}).get("variations", {}).get("plural", {})) != {"one", "other"}:
    raise SystemExit("%lld points must define English one/other plural forms")
if set(plural.get("zh-Hans", {}).get("variations", {}).get("plural", {})) != {"other"}:
    raise SystemExit("%lld points must define the zh-Hans other plural form")

sources = "\n".join(path.read_text() for path in sorted(source_root.rglob("*.swift")))
constructor = re.compile(r'\b(?:Text|Button|Toggle|Menu|Label|Section|CommandMenu)\("((?:\\.|[^"\\])*)"')
modifiers = re.compile(r'\.(?:help|accessibilityLabel|accessibilityValue)\("((?:\\.|[^"\\])*)"')
localized = re.compile(r'String\(\s*localized:\s*"((?:\\.|[^"\\])*)"')

def swift_shape(value):
    output = []
    index = 0
    while index < len(value):
        if value.startswith(r"\(", index):
            depth = 1
            index += 2
            while index < len(value) and depth:
                if value[index] == "(":
                    depth += 1
                elif value[index] == ")":
                    depth -= 1
                index += 1
            output.append("%")
        else:
            output.append(value[index])
            index += 1
    return "".join(output)

catalog_shapes = {printf_pattern.sub("%", key) for key in strings}
literals = constructor.findall(sources) + modifiers.findall(sources) + localized.findall(sources)
for literal in literals:
    if swift_shape(literal) not in catalog_shapes:
        raise SystemExit(f"user-visible literal shape missing from catalog: {literal!r}")

app_source = (source_root / "App/EqualizerAUM1App.swift").read_text()
approved_dynamic_text = {
    "language.titleKey", "statusText", "label", 'details.joined(separator: " · "',
    "nodeTitle(node.kind", "nodeSubtitle(node", "ir.sourcePath",
    "channelSummary(node.channels", "validationMessage",
}
dynamic_text = set(re.findall(r'\bText\((?!")([^\n]+?)\)', app_source))
if dynamic_text != approved_dynamic_text:
    raise SystemExit(f"dynamic Text review set changed: {sorted(dynamic_text)}")
approved_dynamic_help = {
    "nodeToggleLabel(node", "graphicEQDiagnosticSummary(node.id", "ir.sourcePath",
    "nodeSubtitle(node", "selectedPointIDs.contains(point.id", "help",
}
dynamic_help = set(re.findall(r'\.help\((?!")([^\n]+?)\)', app_source))
if dynamic_help != approved_dynamic_help:
    raise SystemExit(f"dynamic help review set changed: {sorted(dynamic_help)}")
approved_fixed = {
    'Text("Select").frame(width: 34)',
    'Text("Frequency (Hz)").frame(width: 140, alignment: .leading)',
    'Text("Gain (dB)").frame(width: 120, alignment: .leading)',
}
fixed = set(re.findall(r'Text\("[^"\\]+"\)\.frame\(width: [^\n]+\)', app_source))
if fixed != approved_fixed:
    raise SystemExit(f"localized fixed-width exemptions changed: {sorted(fixed)}")
required_app_commands = {
    ".commandsRemoved()",
    "CommandGroup(replacing: .appTermination)",
    'Button("Quit EqualizerAU") { NSApp.terminate(nil) }',
    '.keyboardShortcut("q")',
    "CommandGroup(replacing: .appVisibility)",
    "NSApp.setActivationPolicy(.regular)",
    "makeStatusIcon()",
    "image.isTemplate = true",
    "M1StatusIndicatorView",
    "NSColor.systemGreen",
    "NSColor.systemBlue",
    "NSColor.systemRed",
    "statusIndicator?.state = hasError ? .error : snapshot.processingEnabled ? .active : .inactive",
}
for required in required_app_commands:
    if required not in app_source:
        raise SystemExit(f"required app command missing: {required!r}")
for forbidden in (
    "CommandGroup(replacing: .textFormatting)",
    "CommandGroup(replacing: .help)",
    "NSApp.setActivationPolicy(.accessory)",
    "makeStatusIcon(hasError:",
):
    if forbidden in app_source:
        raise SystemExit(f"forbidden menu or Dock lifecycle command: {forbidden}")
status_icon_block = app_source.split("private func updateStatusItem", 1)[1].split(
    "private func statusText", 1
)[0]
for symbol in ("waveform", "speaker.slash", "stop.circle", "arrow.triangle.2.circlepath"):
    if f'"{symbol}"' in status_icon_block:
        raise SystemExit(f"system media symbol is forbidden for the status icon: {symbol}")
for required in ("Retry the final sync for generation %llu, or exit without claiming which complete file is on disk.", "Audio device monitoring is unavailable; waiting for a system device event.", "The keyboard adjustment would exceed a range or duplicate a frequency."):
    if required not in strings:
        raise SystemExit(f"required long presentation missing: {required!r}")
PY

if rg -n 'AppleLanguages|method_exchangeImplementations|class_replaceMethod' "$repo_root/EqualizerAUM1"; then
  print -u2 -- "global language mutation or swizzling is forbidden"; exit 1
fi
if rg -n 'alert\.(messageText|informativeText) = "|addButton\(withTitle: "|visibleError = "|\.stayOpen\("' "$repo_root/EqualizerAUM1"; then
  print -u2 -- "raw presentation/error text must use a structured localization boundary"; exit 1
fi

print -- "M9 localization gates passed"
