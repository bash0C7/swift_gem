# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "swift_gem/mkmf"

class SwiftGemMkmfTest < Test::Unit::TestCase
  test "create_swift_makefile writes Makefile with SPM rpath linker flags" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        SwiftGem::Mkmf.create_swift_makefile(
          "toy_gem/toy_gem",
          package: "Toy",
          builder: ->(_package) { File.expand_path(".build/release") }
        )

        assert(File.exist?("Makefile"), "Makefile should be generated")
        content = File.read("Makefile")
        assert_match(%r{^SHELL = /bin/sh$}, content)
        assert_match(%r{-Wl,-rpath,.*\.build/release}, content)
        assert_match(%r{-L.*\.build/release}, content)
        assert_match(/-lToy/, content)
      end
    end
  end
end
