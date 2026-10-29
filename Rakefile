# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

desc "Validate the RBS signatures"
task :rbs do
  sh "rbs", "-I", "sig", "validate"
end
task test: :rbs

desc "Start an IRB console with swift_gem preloaded"
task :console do
  require "irb"
  require_relative "lib/swift_gem"
  require_relative "lib/swift_gem/mkmf"
  require_relative "lib/swift_gem/generator"
  ARGV.clear
  IRB.start
end

desc 'Scaffold a new swift-extension gem: rake "new[gem_name,dest_dir]"'
task :new, [:gem_name, :dest_dir] do |_task, args|
  gem_name = args[:gem_name]
  abort 'usage: bundle exec rake "new[rb-hello-swift,../rb-hello-swift]"' unless gem_name

  dest = File.expand_path(args[:dest_dir] || gem_name)
  abort "destination already exists and is not empty: #{dest}" if Dir.exist?(dest) && !Dir.empty?(dest)

  require_relative "lib/swift_gem/generator"
  SwiftGem::Generator.new(gem_name).call(dest_dir: dest)
  puts "Created swift-gem skeleton at #{dest}"
end

task default: :test
