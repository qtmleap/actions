# Each suite has its own process, consumer config and legacy constants.
require "rbconfig"
files = Dir[File.join(__dir__, "*_test.rb")] + Dir[File.join(__dir__, "legacy/*_test.rb")]
failed = files.sort.reject { |file| system(RbConfig.ruby, file) }
abort "Failed suites: #{failed.map { |f| File.basename(f) }.join(', ')}" unless failed.empty?
puts "All shared suites passed"
