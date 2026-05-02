# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

desc "Verify the active Swift toolchain is 6.3 or newer (SE-0495 @c)"
task :check do
  $LOAD_PATH.unshift File.expand_path("lib", __dir__)
  require "swift_gem/swift_version_check"
  begin
    version = SwiftGem::SwiftVersionCheck.call!
    puts "swift_gem: Swift #{version} OK"
  rescue SwiftGem::SwiftVersionCheck::IncompatibleSwiftVersion => e
    abort e.message
  end
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end
task test: :check

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

desc "Scaffold a new swift-extension gem: rake new <gem_name> [dest_dir]"
task :new do
  # Rake normally treats positional ARGV entries as task names. Read them
  # directly and stub each one as a no-op task so Rake stops complaining.
  positional = ARGV.drop(1)
  if positional.empty?
    warn "usage: bundle exec rake new <gem_name> [dest_dir]"
    exit 1
  end
  positional.each { |arg| task(arg.to_sym) {} }

  gem_name, dest_arg = positional
  dest = dest_arg || File.join(Dir.pwd, gem_name)
  if File.exist?(dest) && !Dir.empty?(dest)
    warn "destination already exists and is not empty: #{dest}"
    exit 2
  end

  $LOAD_PATH.unshift File.expand_path("lib", __dir__)
  require "swift_gem/generator"
  SwiftGem::Generator.new(gem_name).call(dest_dir: dest)
  puts "Created swift-gem skeleton at #{dest}"
end

task default: :test
