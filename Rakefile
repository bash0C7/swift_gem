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

desc "Scaffold a new swift-extension gem: rake \"new[rb-foo-mac]\" or rake \"new[rb-foo-mac,/path/to/dest]\""
task :new, [:gem_name, :dest] do |_, args|
  unless args[:gem_name]
    warn 'usage: rake "new[gem_name]" or rake "new[gem_name,dest_dir]"'
    exit 1
  end

  $LOAD_PATH.unshift File.expand_path("lib", __dir__)
  require "swift_gem/generator"

  dest = args[:dest] || File.join(Dir.pwd, args[:gem_name])
  if File.exist?(dest) && !Dir.empty?(dest)
    warn "destination already exists and is not empty: #{dest}"
    exit 2
  end

  SwiftGem::Generator.new(args[:gem_name]).call(dest_dir: dest)
  puts "Created swift-gem skeleton at #{dest}"
end

task default: :test
