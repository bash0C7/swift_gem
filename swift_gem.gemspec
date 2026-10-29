# frozen_string_literal: true

require_relative "lib/swift_gem/version"

Gem::Specification.new do |spec|
  spec.name = "swift_gem"
  spec.version = SwiftGem::VERSION
  spec.authors = ["bash0C7"]
  spec.email = ["ksb.4038.nullpointer+github@gmail.com"]

  spec.summary = "Helpers for compiling Swift Package Manager-backed Ruby native extensions on macOS"
  spec.description = "Provides mkmf and rake helpers to build Ruby C extensions whose implementation lives in Swift via SPM. Targets Apple platform frameworks (Vision, AVFoundation, NaturalLanguage, Speech, etc.) reachable from Swift."
  spec.homepage = "https://github.com/bash0C7/swift_gem"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/bash0C7/swift_gem"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ CLAUDE.md docs/ .claude/])
    end
  end
  spec.require_paths = ["lib"]
end
