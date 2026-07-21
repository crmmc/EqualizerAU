#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h}"

/usr/bin/ruby - "$repo_root" <<'RUBY'
require "set"

repo_root = ARGV.fetch(0)

audits = {
  "EqualizerAUM1/Audio/EAUM1AudioIOHost.mm" => [
    "CallbackScope(",
    "~CallbackScope(",
    "RenderOwnership(",
    "~RenderOwnership(",
    "bool checkedSampleCount(",
    "bool validateABL(",
    "bool validateInterleavedOutput(",
    "void clearOutput(",
    "void setSilenceFlag(",
    "uint64_t availableFrames(",
    "OSStatus captureCallback(",
    "OSStatus renderCallback(",
    "EAUM1Status EAUM1AudioIOHostCapture(",
    "EAUM1Status EAUM1AudioIOHostRender(",
  ],
  "EqualizerAUM1Runtime/src/EAUM1Runtime.cpp" => [
    "void beginChainTransitionIfNeeded(",
    "void beginEffectsTransitionIfNeeded(",
    "void advanceEffectsTransition(",
    "float sanitizeInput(",
    "double boundedDSPValue(",
    "float normalizedFloatSample(",
    "float processChainSample(",
    "float mixSamples(",
    "void completeChainTransitionFrame(",
    "EAUM1Status validateProcessCall(",
    "void silenceOutputBlock(",
    "EAUM1Status EAUM1RuntimeProcess(",
  ],
}

forbidden = {
  "dynamic allocation" => /\b(?:new|delete|malloc|calloc|realloc|free|make_unique|make_shared|allocate|deallocate)\b|operator\s+new|\.(?:push_back|emplace_back|reserve|resize|assign|insert)\s*\(/,
  "locking or waiting" => /\b(?:mutex|lock_guard|unique_lock|scoped_lock|condition_variable|semaphore|usleep|sleep|nanosleep|pthread_(?:mutex|rwlock|cond|spin)_\w+|os_unfair_lock\w*)\b|\.(?:lock|wait|wait_for|wait_until)\s*\(|std::this_thread::(?:sleep_for|sleep_until)\s*\(/,
  "logging or formatting" => /\b(?:printf|fprintf|sprintf|snprintf|NSLog|os_log|syslog)\s*\(|std::(?:cout|cerr|clog|wcout|wcerr|wclog|string|stringstream|ostringstream|istringstream)/,
  "file or network I/O" => /\b(?:open|close|read|write|pread|pwrite|fopen|fclose|fread|fwrite|socket|connect|accept|send|recv)\s*\(/,
  "dispatch or Objective-C messaging" => /\b(?:dispatch_async|dispatch_sync|dispatch_after|objc_msgSend)\b|^\s*\[[A-Za-z_]\w*\s+[A-Za-z_]\w*(?::[^\]\n]*)?\]\s*;?\s*$/,
  "exceptions" => /\b(?:throw|catch)\b/,
}

def function_body(source, marker)
  marker_index = source.index(marker)
  abort("missing realtime function marker: #{marker}") unless marker_index

  open_index = source.index("{", marker_index)
  abort("missing function body for marker: #{marker}") unless open_index

  depth = 0
  index = open_index
  while index < source.length
    case source.getbyte(index)
    when 123
      depth += 1
    when 125
      depth -= 1
      return source[marker_index..index] if depth.zero?
    end
    index += 1
  end
  abort("unterminated function body for marker: #{marker}")
end

audited_count = 0
audited_bodies = []
audited_names = audits.values.flatten.map { |marker| marker[/~?[A-Za-z_]\w*(?=\()/] }.to_set
sources = audits.keys.to_h do |relative_path|
  [relative_path, File.read(File.join(repo_root, relative_path))]
end
local_names = sources.values.flat_map do |source|
  source.scan(/^\s*(?:[A-Za-z_]\w*(?:::\w+)*(?:\s*[<>&*]\s*|\s+))+([A-Za-z_]\w*)\s*\([^;{}]*\)\s*(?:const\s*)?\{/m).flatten
end.to_set

audits.each do |relative_path, markers|
  source = sources.fetch(relative_path)
  markers.each do |marker|
    body = function_body(source, marker)
    forbidden.each do |category, pattern|
      abort("#{relative_path}: #{marker} contains forbidden #{category}") if body.match?(pattern)
    end
    body.scan(/\b([A-Za-z_]\w*)\s*\(/).flatten.each do |called|
      next unless local_names.include?(called)
      abort("#{relative_path}: #{marker} calls unaudited local helper #{called}") unless audited_names.include?(called)
    end
    audited_count += 1
  end
end

puts "M1 realtime source audit OK: #{audited_count} explicit functions; same-file bare-name direct calls checked"
RUBY
