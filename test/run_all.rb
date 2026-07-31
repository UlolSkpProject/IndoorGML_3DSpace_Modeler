# frozen_string_literal: true

require 'open3'
require 'rbconfig'

test_files = Dir[File.join(__dir__, 'test_*.rb')].sort
failures = []

test_files.each do |file|
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, file, *ARGV)
  next if status.success?

  failures << file
  warn "\n=== FAILED: #{File.basename(file)} ==="
  $stdout.write(stdout)
  $stderr.write(stderr)
end

if failures.empty?
  puts "#{test_files.length} test files passed in isolated Ruby processes."
  exit 0
end

warn "#{failures.length} of #{test_files.length} test files failed."
exit 1
