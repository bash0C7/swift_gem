# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "swift_gem/mkmf"

class SwiftGemMkmfTest < Test::Unit::TestCase
  test "create_swift_makefile passes source_dir to builder and embeds rpath ldflags" do
    received_args = nil
    builder = lambda do |package, source_dir|
      received_args = [package, source_dir]
      File.expand_path(".build/release", source_dir)
    end

    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        SwiftGem::Mkmf.create_swift_makefile(
          "toy_gem/toy_gem",
          package: "Toy",
          source_dir: "/some/swift/pkg/dir",
          builder: builder
        )

        assert_equal(["Toy", "/some/swift/pkg/dir"], received_args)
        assert(File.exist?("Makefile"), "Makefile should be generated")
        content = File.read("Makefile")
        assert_match(%r{^SHELL = /bin/sh$}, content)
        assert_match(%r{-Wl,-rpath,/some/swift/pkg/dir/\.build/release}, content)
        assert_match(%r{-L/some/swift/pkg/dir/\.build/release}, content)
        assert_match(/-lToy/, content)
      end
    end
  end
end
