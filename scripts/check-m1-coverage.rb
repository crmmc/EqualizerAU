#!/usr/bin/ruby

require "json"
require "open3"
require "pathname"

repo_root = Pathname.new(__dir__).join("..").realpath
result_bundle = Pathname.new(ARGV.fetch(0, repo_root.join("build/coverage/EqualizerAU.xcresult").to_s)).realpath

included_sources = %w[
  EqualizerAUM1/App/M1AppModel.swift
  EqualizerAUM1/Configuration/M1ProcessingModel.swift
  EqualizerAUM1/Configuration/M1ConvolutionIR.swift
  EqualizerAUM1/Configuration/M1ProcessingBuilder.swift
  EqualizerAUM1/Configuration/M1Configuration.swift
  EqualizerAUM1/Configuration/M1ConfigurationStore.swift
  EqualizerAUM1/Control/M1RetirementMaintenanceCoordinator.swift
  EqualizerAUM1/Audio/M1AudioRouteModel.swift
  EqualizerAUM1/Audio/M1AudioIOController.swift
  EqualizerAUM1/Control/M1RuntimeLeaseAccess.swift
  EqualizerAUM1/Audio/M1NativeAudioRouteCoordinator.swift
  EqualizerAUM1/Audio/M1SystemAudioLifecycleMonitor.swift
  EqualizerAUM1/Control/M1ProductController.swift
  EqualizerAUM1/Control/M1EditingSession.swift
  EqualizerAUM1Runtime/src/EAUM1Runtime.cpp
].freeze

excluded_sources = {
  "EqualizerAUM1/App/EqualizerAUM1App.swift" => "SwiftUI/AppKit composition and app-host wiring",
  "EqualizerAUM1/App/M1SystemAppAdapters.swift" => "NSApplication, panels, alerts, and pasteboard adapter",
  "EqualizerAUM1/Audio/M1SystemAudioIO.swift" => "direct Core Audio and C ABI adapter",
  "EqualizerAUM1/Audio/M1SystemAudioLifecycleOperations.swift" => "direct Core Audio property listener adapter",
  "EqualizerAUM1/Audio/M1SystemCoreAudioHAL.swift" => "direct Core Audio property adapter mixed with parser pending separation",
  "EqualizerAUM1/Audio/EAUM1AudioIOHost.mm" => "direct Core Audio registration mixed with callback core pending separation",
}.freeze

critical_sources = %w[
  EqualizerAUM1/App/M1AppModel.swift
  EqualizerAUM1/Configuration/M1Configuration.swift
  EqualizerAUM1/Configuration/M1ConfigurationStore.swift
  EqualizerAUM1/Configuration/M1ProcessingBuilder.swift
  EqualizerAUM1/Control/M1ProductController.swift
  EqualizerAUM1/Control/M1EditingSession.swift
  EqualizerAUM1/Audio/M1AudioIOController.swift
  EqualizerAUM1/Audio/M1NativeAudioRouteCoordinator.swift
  EqualizerAUM1/Audio/M1SystemAudioLifecycleMonitor.swift
  EqualizerAUM1Runtime/src/EAUM1Runtime.cpp
].freeze

overall_threshold = 0.95
critical_threshold = 0.90
runtime_threshold = 0.95

main_paths = {
  "configuration bootstrap and recovery" => "testFirstLaunchEstablishesPreviousBeforeMain",
  "editing and durable save" => "testRunningSavePersistsBeforePublishingCompiledCandidate",
  "capture-first start and reverse-order stop" => "testCaptureMustStartBeforeOutputAndStopOrderIsOutputFirst",
  "processing bypass and fresh activation" => "testComputationalBypassDisablesAndFreshlyActivatesWithoutRouteRebuild",
  "route and format recovery" => "testOutputFormatChangeRestartsWithFormatRecoveryMode",
  "capture permission verification" => "testForegroundPermissionVerificationUsesSameOwnedRouteTap",
  "DSP build and runtime processing" => "testInitialTargetsApplyDirectlyAcrossMixedBufferTopology",
  "pending application diagnostics promotion" => "testPendingPublicationPromotesExpectedDiagnostics",
  "realtime diagnostics snapshot" => "testDiagnosticsPropagateHostCountersForOwnedResource",
  "termination save and ordered shutdown" => "testSaveAndExitPersistsDraftThenPerformsOrderedShutdown",
}.freeze

stdout, stderr, status = Open3.capture3(
  "xcrun", "xccov", "view", "--report", "--json", result_bundle.to_s
)
abort(stderr.empty? ? "xccov failed" : stderr) unless status.success?
report = JSON.parse(stdout)

relative_path = lambda do |path|
  Pathname.new(path).realpath.relative_path_from(repo_root).to_s
rescue ArgumentError, Errno::ENOENT
  nil
end

records = Hash.new { |hash, key| hash[key] = [] }
report.fetch("targets").each do |target|
  target.fetch("files").each do |file|
    relative = relative_path.call(file.fetch("path"))
    records[relative] << file.merge("targetName" => target.fetch("name")) if relative
  end
end

unknown_production = records.keys.grep(%r{\A(?:EqualizerAUM1/|EqualizerAUM1Runtime/src/)}) - included_sources - excluded_sources.keys
abort("Coverage policy does not classify production sources:\n  #{unknown_production.sort.join("\n  ")}") unless unknown_production.empty?

missing = included_sources.reject { |path| records.key?(path) }
abort("Coverage report is missing included production sources:\n  #{missing.join("\n  ")}") unless missing.empty?

canonical = included_sources.to_h do |path|
  record = records.fetch(path).max_by { |candidate| [candidate.fetch("coveredLines"), candidate.fetch("lineCoverage")] }
  [path, record]
end

covered = canonical.values.sum { |file| file.fetch("coveredLines") }
executable = canonical.values.sum { |file| file.fetch("executableLines") }
overall = executable.zero? ? 0.0 : covered.fdiv(executable)

rows = canonical.map do |path, file|
  [path, file.fetch("lineCoverage"), file.fetch("coveredLines"), file.fetch("executableLines"), file.fetch("targetName")]
end.sort_by { |row| [row[1], row[0]] }

puts format("Core production logic: %.2f%% (%d/%d), required %.2f%%", overall * 100, covered, executable, overall_threshold * 100)
rows.each do |path, coverage, file_covered, file_executable, target|
  puts format("  %6.2f%%  %5d/%-5d  %-70s [%s]", coverage * 100, file_covered, file_executable, path, target)
end

raw_app = report.fetch("targets").find { |target| target.fetch("name") == "EqualizerAU.app" }
if raw_app
  puts format(
    "Raw app target (reported only): %.2f%% (%d/%d)",
    raw_app.fetch("lineCoverage") * 100,
    raw_app.fetch("coveredLines"),
    raw_app.fetch("executableLines")
  )
end

puts "Excluded platform/UI glue:"
excluded_sources.each do |path, reason|
  coverage = records[path]&.max_by { |candidate| candidate.fetch("coveredLines") }&.fetch("lineCoverage", nil)
  suffix = coverage ? format(" (observed %.2f%%)", coverage * 100) : " (not present in this hostless report)"
  puts "  #{path}: #{reason}#{suffix}"
end

failures = []
failures << format("overall %.2f%% is below %.2f%%", overall * 100, overall_threshold * 100) if overall < overall_threshold
critical_sources.each do |path|
  coverage = canonical.fetch(path).fetch("lineCoverage")
  failures << format("%s %.2f%% is below %.2f%%", path, coverage * 100, critical_threshold * 100) if coverage < critical_threshold
end
runtime_coverage = canonical.fetch("EqualizerAUM1Runtime/src/EAUM1Runtime.cpp").fetch("lineCoverage")
if runtime_coverage < runtime_threshold
  failures << format("Runtime %.2f%% is below %.2f%%", runtime_coverage * 100, runtime_threshold * 100)
end

tests_stdout, tests_stderr, tests_status = Open3.capture3(
  "xcrun", "xcresulttool", "get", "test-results", "tests", "--path", result_bundle.to_s
)
abort(tests_stderr.empty? ? "xcresult test listing failed" : tests_stderr) unless tests_status.success?
test_results = {}
collect_tests = lambda do |value|
  case value
  when Hash
    if value["nodeType"] == "Test Case"
      test_results[value.fetch("name").delete_suffix("()")] = value.fetch("result")
    end
    value.each_value { |child| collect_tests.call(child) }
  when Array
    value.each { |child| collect_tests.call(child) }
  end
end
collect_tests.call(JSON.parse(tests_stdout))
main_paths.each do |path, test_name|
  result = test_results[test_name]
  failures << "main path #{path.inspect} is not covered by passing #{test_name} (#{result || "missing"})" unless result == "Passed"
end
puts "Main functional paths: #{main_paths.count}/#{main_paths.count} passed" if failures.none? { |failure| failure.start_with?("main path ") }

summary = [
  "## M1 coverage",
  "",
  format("Core production logic: **%.2f%%** (%d/%d), required **%.2f%%**.", overall * 100, covered, executable, overall_threshold * 100),
  failures.empty? ? "Result: **PASS**" : "Result: **FAIL**",
]
if ENV["GITHUB_STEP_SUMMARY"]
  File.open(ENV.fetch("GITHUB_STEP_SUMMARY"), "a") { |file| file.puts(summary.join("\n")) }
end

abort("Coverage gate failed:\n  #{failures.join("\n  ")}") unless failures.empty?
puts "Coverage gate passed"
