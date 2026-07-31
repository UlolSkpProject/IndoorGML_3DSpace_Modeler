# frozen_string_literal: true

require 'rbconfig'

test_files = Dir[File.join(__dir__, 'test_*.rb')].sort
failed_files = []

test_files.each do |file|
  puts "\n=== #{File.basename(file)} ==="
  success = system(RbConfig.ruby, file)
  failed_files << file unless success
end

unless failed_files.empty?
  warn "\nFailed test files (#{failed_files.length}):"
  failed_files.each { |file| warn "  - #{File.basename(file)}" }
  exit 1
end
