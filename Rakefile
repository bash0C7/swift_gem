# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

desc "Start an IRB console with swift_gem preloaded"
task :console do
  require "irb"
  $LOAD_PATH.unshift File.expand_path("lib", __dir__)
  require "swift_gem"
  require "swift_gem/mkmf"
  require "swift_gem/generator"
  ARGV.clear
  IRB.start
end

task default: :test
