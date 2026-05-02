# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "swift_gem/mkmf"
require "swift_gem/swift_version_check"

class SwiftGemMkmfTest < Test::Unit::TestCase
  StubBuilder = lambda do |_package, source_dir|
    File.expand_path(".build/release", source_dir)
  end

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
          builder: builder,
          swift_version_probe: -> { "Apple Swift version 6.3.0\n" }
        )

        assert_equal(["Toy", "/some/swift/pkg/dir"], received_args)
        assert(File.exist?("Makefile"), "Makefile should be generated")
        content = File.read("Makefile")
        assert_match(%r{^SHELL = /bin/sh$}, content)
        assert_match(%r{-Wl,-rpath,/some/swift/pkg/dir/\.build/release}, content)
        assert_match(%r{-L/some/swift/pkg/dir/\.build/release}, content)
        assert_match(/-lToy/, content)
        assert_match(%r{-I/some/swift/pkg/dir/\.build/release}, content,
                     "CFLAGS should include the SPM build dir so the C ext can #include the auto-generated <Package>-Swift.h")
      end
    end
  end

  test "create_swift_makefile rejects toolchain older than 6.3 before invoking builder" do
    builder_called = false
    builder = lambda do |_package, source_dir|
      builder_called = true
      File.expand_path(".build/release", source_dir)
    end

    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        assert_raise(SwiftGem::SwiftVersionCheck::IncompatibleSwiftVersion) do
          SwiftGem::Mkmf.create_swift_makefile(
            "toy_gem/toy_gem",
            package: "Toy",
            source_dir: "/some/swift/pkg/dir",
            builder: builder,
            swift_version_probe: -> { "Apple Swift version 6.2.4\n" }
          )
        end
        assert_false(builder_called, "builder should not run when Swift toolchain is too old")
      end
    end
  end
end
