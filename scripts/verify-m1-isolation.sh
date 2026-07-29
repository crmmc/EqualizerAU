#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h}"
project="$repo_root/EqualizerAU.xcodeproj"
pbxproj="$project/project.pbxproj"
scheme="$project/xcshareddata/xcschemes/EqualizerAUM1.xcscheme"

required_targets=(
  EqualizerAUM1Runtime
  EqualizerAUM1
  EqualizerAUM1RuntimeTests
  EqualizerAUM1Tests
  EqualizerAUM1IntegrationTests
)

project_listing="$(xcodebuild -project "$project" -list -json)"
print -r -- "$project_listing" | /usr/bin/ruby -rjson -e '
  targets = JSON.parse(STDIN.read).fetch("project").fetch("targets")
  missing = ARGV.reject { |target| targets.include?(target) }
  abort("missing M1 targets: #{missing.join(", ")}") unless missing.empty?
' "${required_targets[@]}"

/usr/bin/ruby - "$pbxproj" "$scheme" "$repo_root" <<'RUBY'
require "json"
require "open3"
require "rexml/document"

pbxproj_path = ARGV.fetch(0)
scheme_path = ARGV.fetch(1)
repo_root = ARGV.fetch(2)
json, status = Open3.capture2("/usr/bin/plutil", "-convert", "json", "-o", "-", pbxproj_path)
abort("unable to parse #{pbxproj_path}") unless status.success?

project = JSON.parse(json)
objects = project.fetch("objects")
targets_by_name = objects.each_with_object({}) do |(id, object), result|
  result[object.fetch("name")] = [id, object] if object["isa"] == "PBXNativeTarget"
end

parent_groups = {}
objects.each do |id, object|
  next unless object["isa"] == "PBXGroup"
  object.fetch("children", []).each { |child| parent_groups[child] = id }
end

path_for = lambda do |file_id|
  file = objects.fetch(file_id)
  parts = [file["path"] || file["name"]].compact
  parent = parent_groups[file_id]
  while parent
    group = objects.fetch(parent)
    parts.unshift(group["path"]) if group["path"]
    parent = parent_groups[parent]
  end
  parts.join("/")
end

build_file_paths = lambda do |phase|
  phase.fetch("files", []).map do |build_file_id|
    build_file = objects.fetch(build_file_id)
    path_for.call(build_file.fetch("fileRef"))
  end
end

contracts = {
  "EqualizerAUM1Runtime" => {
    product_type: "com.apple.product-type.library.static",
    product: "libEqualizerAUM1Runtime.a",
    sources: ["EqualizerAUM1Runtime/src/EAUM1Runtime.cpp"],
    phase_types: %w[PBXSourcesBuildPhase PBXFrameworksBuildPhase],
    frameworks: [],
    dependencies: [],
    bridging_header: nil,
    test_host: nil,
  },
  "EqualizerAUM1" => {
    product_type: "com.apple.product-type.application",
    product: "EqualizerAU.app",
    sources: [
      "EqualizerAUM1/App/EqualizerAUM1App.swift",
      "EqualizerAUM1/Configuration/M1ProcessingModel.swift",
      "EqualizerAUM1/Configuration/M1ConvolutionIR.swift",
      "EqualizerAUM1/Configuration/M1ProcessingBuilder.swift",
      "EqualizerAUM1/Configuration/M1Configuration.swift",
      "EqualizerAUM1/Configuration/M1ConfigurationStore.swift",
      "EqualizerAUM1/Control/M1RetirementMaintenanceCoordinator.swift",
      "EqualizerAUM1/Audio/M1AudioRouteModel.swift",
      "EqualizerAUM1/Audio/M1SystemCoreAudioHAL.swift",
      "EqualizerAUM1/Audio/EAUM1AudioIOHost.mm",
      "EqualizerAUM1/Audio/M1AudioIOController.swift",
      "EqualizerAUM1/Audio/M1SystemAudioIO.swift",
      "EqualizerAUM1/Control/M1RuntimeLeaseAccess.swift",
      "EqualizerAUM1/Audio/M1NativeAudioRouteCoordinator.swift",
      "EqualizerAUM1/Control/M1ProductController.swift",
      "EqualizerAUM1/Audio/M1SystemAudioLifecycleMonitor.swift",
      "EqualizerAUM1/Control/M1EditingSession.swift",
    ],
    phase_types: %w[PBXSourcesBuildPhase PBXFrameworksBuildPhase PBXResourcesBuildPhase],
    frameworks: ["libEqualizerAUM1Runtime.a", "System/Library/Frameworks/CoreAudio.framework", "System/Library/Frameworks/AudioToolbox.framework"],
    dependencies: ["EqualizerAUM1Runtime"],
    bridging_header: "EqualizerAUM1/EqualizerAUM1-Bridging-Header.h",
    test_host: nil,
  },
  "EqualizerAUM1RuntimeTests" => {
    product_type: "com.apple.product-type.bundle.unit-test",
    product: "EqualizerAUM1RuntimeTests.xctest",
    sources: [
      "EqualizerAUM1RuntimeTests/EAUM1RuntimeSmokeTests.mm",
      "EqualizerAUM1/Configuration/M1ProcessingModel.swift",
      "EqualizerAUM1RuntimeTests/M1ProcessingModelTests.swift",
      "EqualizerAUM1/Configuration/M1ConvolutionIR.swift",
      "EqualizerAUM1RuntimeTests/M1ConvolutionIRTests.swift",
      "EqualizerAUM1/Configuration/M1ProcessingBuilder.swift",
      "EqualizerAUM1RuntimeTests/M1ProcessingBuilderTests.swift",
      "EqualizerAUM1/Configuration/M1Configuration.swift",
      "EqualizerAUM1/Configuration/M1ConfigurationStore.swift",
      "EqualizerAUM1RuntimeTests/M1ConfigurationCodecTests.swift",
      "EqualizerAUM1RuntimeTests/M1ConfigurationStoreTests.swift",
      "EqualizerAUM1/Control/M1RetirementMaintenanceCoordinator.swift",
      "EqualizerAUM1RuntimeTests/M1RetirementMaintenanceCoordinatorTests.swift",
      "EqualizerAUM1/Audio/M1AudioRouteModel.swift",
      "EqualizerAUM1/Audio/M1SystemCoreAudioHAL.swift",
      "EqualizerAUM1/Audio/EAUM1AudioIOHost.mm",
      "EqualizerAUM1/Audio/M1AudioIOController.swift",
      "EqualizerAUM1/Control/M1RuntimeLeaseAccess.swift",
      "EqualizerAUM1/Audio/M1NativeAudioRouteCoordinator.swift",
      "EqualizerAUM1/Control/M1ProductController.swift",
      "EqualizerAUM1/Control/M1EditingSession.swift",
      "EqualizerAUM1RuntimeTests/EAUM1AudioIOHostTests.mm",
      "EqualizerAUM1RuntimeTests/M1AudioRouteResourceControllerTests.swift",
      "EqualizerAUM1RuntimeTests/M1AudioIOControllerTests.swift",
      "EqualizerAUM1RuntimeTests/M1CoreAudioDataParserTests.swift",
      "EqualizerAUM1RuntimeTests/M1ProductControllerTests.swift",
      "EqualizerAUM1RuntimeTests/M1EditingSessionTests.swift",
      "EqualizerAUM1RuntimeTests/M1EditingPerformanceTests.swift",
    ],
    phase_types: %w[PBXSourcesBuildPhase PBXFrameworksBuildPhase PBXResourcesBuildPhase],
    frameworks: ["System/Library/Frameworks/XCTest.framework", "libEqualizerAUM1Runtime.a", "System/Library/Frameworks/CoreAudio.framework", "System/Library/Frameworks/AudioToolbox.framework"],
    dependencies: ["EqualizerAUM1Runtime"],
    bridging_header: "EqualizerAUM1/EqualizerAUM1-Bridging-Header.h",
    test_host: nil,
  },
  "EqualizerAUM1Tests" => {
    product_type: "com.apple.product-type.bundle.unit-test",
    product: "EqualizerAUM1Tests.xctest",
    sources: ["EqualizerAUM1Tests/M1RuntimeBootstrapTests.swift"],
    phase_types: %w[PBXSourcesBuildPhase PBXFrameworksBuildPhase PBXResourcesBuildPhase],
    frameworks: ["System/Library/Frameworks/XCTest.framework"],
    dependencies: ["EqualizerAUM1"],
    bridging_header: nil,
    test_host: "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/M1/EqualizerAU.app/Contents/MacOS/EqualizerAU",
  },
  "EqualizerAUM1IntegrationTests" => {
    product_type: "com.apple.product-type.bundle.unit-test",
    product: "EqualizerAUM1IntegrationTests.xctest",
    sources: ["EqualizerAUM1IntegrationTests/M1AppHostIntegrationTests.swift"],
    phase_types: %w[PBXSourcesBuildPhase PBXFrameworksBuildPhase PBXResourcesBuildPhase],
    frameworks: ["System/Library/Frameworks/XCTest.framework"],
    dependencies: ["EqualizerAUM1"],
    bridging_header: nil,
    test_host: "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/M1/EqualizerAU.app/Contents/MacOS/EqualizerAU",
  },
}

forbidden_settings = [
  "EqualizerAU/EqualizerAU-Bridging-Header.h",
  "EqualizerAU/App/",
  "EqualizerAU/Audio/",
  "EqualizerAUTests/",
  "EqualizerAUIntegrationTests/",
  ".build/DerivedData/",
]
m0_root_patterns = [
  /\$\(SRCROOT\)\/EqualizerAU(?=\/|["\s]|\z)/,
  /\$\{SRCROOT\}\/EqualizerAU(?=\/|["\s]|\z)/,
  /#{Regexp.escape(File.join(repo_root, "EqualizerAU"))}(?=\/|["\s]|\z)/,
]

contracts.each do |target_name, contract|
  target_id, target = targets_by_name.fetch(target_name) { abort("missing M1 target #{target_name}") }
  abort("wrong product type for #{target_name}") unless target["productType"] == contract[:product_type]
  abort("wrong product for #{target_name}") unless path_for.call(target.fetch("productReference")) == contract[:product]

  phases = target.fetch("buildPhases").map { |phase_id| objects.fetch(phase_id) }
  phase_types = phases.map { |phase| phase.fetch("isa") }
  abort("unexpected build phases for #{target_name}: #{phase_types.inspect}") unless phase_types == contract[:phase_types]
  abort("copy phase is forbidden for #{target_name}") if phase_types.include?("PBXCopyFilesBuildPhase")

  source_phase = phases.fetch(phase_types.index("PBXSourcesBuildPhase"))
  sources = build_file_paths.call(source_phase)
  abort("unexpected sources for #{target_name}: #{sources.inspect}") unless sources == contract[:sources]

  framework_phase = phases.fetch(phase_types.index("PBXFrameworksBuildPhase"))
  frameworks = build_file_paths.call(framework_phase).sort
  unless frameworks == contract[:frameworks].sort
    abort("unexpected frameworks for #{target_name}: #{frameworks.inspect}")
  end

  resource_index = phase_types.index("PBXResourcesBuildPhase")
  resources = resource_index ? build_file_paths.call(phases.fetch(resource_index)).sort : []
  expected_resources = target_name == "EqualizerAUM1" ? [
    "EqualizerAUM1/Resources/InfoPlist.xcstrings",
    "EqualizerAUM1/Resources/Localizable.xcstrings",
  ] : []
  unless resources == expected_resources
    abort("unexpected copied resources for #{target_name}: #{resources.inspect}")
  end

  dependencies = target.fetch("dependencies", []).map do |dependency_id|
    dependency = objects.fetch(dependency_id)
    dependency_target_id = dependency.fetch("target")
    proxy = objects.fetch(dependency.fetch("targetProxy"))
    unless proxy.fetch("remoteGlobalIDString") == dependency_target_id
      abort("dependency proxy mismatch for #{target_name}")
    end
    objects.fetch(dependency_target_id).fetch("name")
  end
  abort("unexpected dependencies for #{target_name}: #{dependencies.inspect}") unless dependencies == contract[:dependencies]

  configuration_list = objects.fetch(target.fetch("buildConfigurationList"))
  configurations = configuration_list.fetch("buildConfigurations").map { |id| objects.fetch(id) }
  abort("#{target_name} must have Debug and Release settings") unless configurations.map { |c| c.fetch("name") }.sort == %w[Debug Release]

  configurations.each do |configuration|
    settings = configuration.fetch("buildSettings")
    serialized_settings = JSON.generate(settings)
    forbidden_settings.each do |path|
      abort("#{target_name} #{configuration.fetch("name")} references M0 path #{path}") if serialized_settings.include?(path)
    end
    m0_root_patterns.each do |pattern|
      abort("#{target_name} #{configuration.fetch("name")} references M0 source root") if serialized_settings.match?(pattern)
    end
    unless settings["SWIFT_OBJC_BRIDGING_HEADER"] == contract[:bridging_header]
      abort("wrong bridging header for #{target_name} #{configuration.fetch("name")}")
    end
    unless settings["TEST_HOST"] == contract[:test_host]
      abort("wrong test host for #{target_name} #{configuration.fetch("name")}")
    end
    if target_name == "EqualizerAUM1"
      expected_directory = "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/M1"
      abort("wrong isolated product directory for #{configuration.fetch("name")}") unless settings["CONFIGURATION_BUILD_DIR"] == expected_directory
      abort("wrong M1 Swift module name for #{configuration.fetch("name")}") unless settings["PRODUCT_MODULE_NAME"] == "EqualizerAUM1"
      expected_library_path = "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)"
      abort("wrong M1 Runtime library search path for #{configuration.fetch("name")}") unless settings["LIBRARY_SEARCH_PATHS"] == expected_library_path
    end
    if %w[EqualizerAUM1Tests EqualizerAUM1IntegrationTests].include?(target_name)
      expected_module_path = "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/M1"
      abort("wrong M1 module search path for #{target_name} #{configuration.fetch("name")}") unless settings["SWIFT_INCLUDE_PATHS"] == expected_module_path
    end
  end
end

m1_roots = %w[
  EqualizerAUM1/
  EqualizerAUM1Runtime/
  EqualizerAUM1RuntimeTests/
  EqualizerAUM1Tests/
  EqualizerAUM1IntegrationTests/
]
# EqualizerAU.app is the formal product name for both implementations, but M1's
# configuration build directory keeps their normal build artifacts disjoint.
m1_products = contracts.values.map { |contract| contract.fetch(:product) }.reject { |product| product == "EqualizerAU.app" }
m1_target_ids = contracts.keys.map { |name| targets_by_name.fetch(name).first }
m1_root_patterns = m1_roots.map do |root|
  /#{Regexp.escape(root.delete_suffix("/"))}(?=\/|["\s]|\z)/
end
%w[EqualizerAU EqualizerAUTests EqualizerAUIntegrationTests].each do |target_name|
  _target_id, target = targets_by_name.fetch(target_name)

  target.fetch("dependencies", []).each do |dependency_id|
    dependency_target_id = objects.fetch(dependency_id).fetch("target")
    if m1_target_ids.include?(dependency_target_id)
      abort("M0 target #{target_name} depends on M1 target #{objects.fetch(dependency_target_id).fetch("name")}")
    end
  end

  target.fetch("buildPhases").each do |phase_id|
    phase = objects.fetch(phase_id)
    build_file_paths.call(phase).each do |path|
      if m1_roots.any? { |root| path.start_with?(root) } || m1_products.include?(path)
        abort("M0 target #{target_name} #{phase.fetch("isa")} references M1 item #{path}")
      end
    end
  end

  configuration_list = objects.fetch(target.fetch("buildConfigurationList"))
  configuration_list.fetch("buildConfigurations").each do |configuration_id|
    configuration = objects.fetch(configuration_id)
    if target_name == "EqualizerAU" && configuration.fetch("buildSettings")["CONFIGURATION_BUILD_DIR"] == "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/M1"
      abort("M0 target #{target_name} shares the isolated M1 product directory")
    end
    serialized_settings = JSON.generate(configuration.fetch("buildSettings"))
    if m1_root_patterns.any? { |pattern| serialized_settings.match?(pattern) } ||
       m1_products.any? { |product| serialized_settings.include?(product) }
      abort("M0 target #{target_name} #{configuration.fetch("name")} settings reference M1")
    end
  end
end

bridging_header_path = File.join(repo_root, "EqualizerAUM1/EqualizerAUM1-Bridging-Header.h")
bridging_header_lines = File.readlines(bridging_header_path, chomp: true).map(&:strip).reject(&:empty?)
unless bridging_header_lines == ['#include "EAUM1Runtime.h"', '#include "EAUM1AudioIOHost.h"']
  abort("M1 bridging header must import only EAUM1Runtime.h and EAUM1AudioIOHost.h")
end

scheme = REXML::Document.new(File.read(scheme_path))
blueprints = []
scheme.elements.each("//BuildableReference") do |element|
  blueprints << element.attributes.fetch("BlueprintIdentifier").to_s
end
expected_blueprints = contracts.keys.reject { |name| name == "EqualizerAUM1Runtime" }.map { |name| targets_by_name.fetch(name).first }
abort("M1 scheme contains unexpected targets: #{blueprints.uniq.inspect}") unless blueprints.uniq.sort == expected_blueprints.sort
RUBY

for target in "${required_targets[@]}"; do
  for configuration in Debug Release; do
    xcodebuild \
      -project "$project" \
      -target "$target" \
      -configuration "$configuration" \
      -showBuildSettings | /usr/bin/ruby -e '
        target = ARGV.fetch(0)
        configuration = ARGV.fetch(1)
        repo_root = ARGV.fetch(2)
        m0_literals = [
          "EqualizerAU/EqualizerAU-Bridging-Header.h",
          "EqualizerAU/App/",
          "EqualizerAU/Audio/",
          "EqualizerAUTests/",
          "EqualizerAUIntegrationTests/",
          File.join(repo_root, "EqualizerAU") + "/",
        ]

        STDIN.each_line do |line|
          match = line.match(/^\s*([A-Z0-9_]+) = (.*)$/)
          next unless match
          value = match[2]
          if m0_literals.any? { |literal| value.include?(literal) } ||
             value.match?(/#{Regexp.escape(File.join(repo_root, "EqualizerAU"))}(?=\/|\s|\z)/) ||
             value.match?(/(?:\$\(SRCROOT\)|\$\{SRCROOT\})\/EqualizerAU(?=\/|\s|\z)/)
            abort("#{target} #{configuration} resolves an M0 value for #{match[1]}: #{value}")
          end
        end
      ' "$target" "$configuration" "$repo_root"
  done
done

m0_targets=(EqualizerAU EqualizerAUTests EqualizerAUIntegrationTests)
for target in "${m0_targets[@]}"; do
  for configuration in Debug Release; do
    xcodebuild \
      -project "$project" \
      -target "$target" \
      -configuration "$configuration" \
      -showBuildSettings | /usr/bin/ruby -e '
        target = ARGV.fetch(0)
        configuration = ARGV.fetch(1)
        repo_root = ARGV.fetch(2)
        m1_roots = %w[
          EqualizerAUM1
          EqualizerAUM1Runtime
          EqualizerAUM1RuntimeTests
          EqualizerAUM1Tests
          EqualizerAUM1IntegrationTests
        ]
        m1_products = %w[
          libEqualizerAUM1Runtime.a
          EqualizerAUM1RuntimeTests.xctest
          EqualizerAUM1Tests.xctest
          EqualizerAUM1IntegrationTests.xctest
        ]
        root_patterns = m1_roots.map do |root|
          /(?:^|[\s"=])(?:#{Regexp.escape(repo_root)}\/)?#{Regexp.escape(root)}(?=\/|\s|\z)/
        end

        STDIN.each_line do |line|
          match = line.match(/^\s*([A-Z0-9_]+) = (.*)$/)
          next unless match
          value = match[2]
          if root_patterns.any? { |pattern| value.match?(pattern) } ||
             m1_products.any? { |product| value.include?(product) }
            abort("#{target} #{configuration} resolves an M1 value for #{match[1]}: #{value}")
          end
        end
      ' "$target" "$configuration" "$repo_root"
  done
done

print "M1 isolation OK: ${#required_targets[@]} targets\n"
