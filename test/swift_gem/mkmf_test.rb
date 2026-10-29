# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "shellwords"
require "swift_gem/mkmf"

class SwiftGemMkmfTest < Test::Unit::TestCase
  def makefile_for(lib_dir:, header_dir:)
    received_args = nil
    builder = lambda do |package, source_dir|
      received_args = [package, source_dir]
      [lib_dir, header_dir]
    end

    content = nil
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        SwiftGem::Mkmf.create_swift_makefile(
          "toy_gem/toy_gem",
          package: "Toy",
          source_dir: "/some/swift/pkg/dir",
          builder: builder
        )
        assert(File.exist?("Makefile"), "Makefile should be generated")
        content = File.read("Makefile")
      end
    end
    [content, received_args]
  end

  test "create_swift_makefile passes package and source_dir to builder and embeds its paths" do
    content, received_args = makefile_for(
      lib_dir: "/some/lib/release",
      header_dir: "/some/header/modules"
    )

    assert_equal(["Toy", "/some/swift/pkg/dir"], received_args)
    assert_match(%r{^SHELL = /bin/sh$}, content)
    assert_include(content, "-I/some/header/modules")
    assert_include(content, "-Wl,-rpath,/some/lib/release")
    assert_include(content, "-L/some/lib/release")
    assert_include(content, "-lToy")
  end

  test "create_swift_makefile escapes paths containing spaces" do
    lib_dir = "/some lib/release"
    header_dir = "/some header/modules"
    content, = makefile_for(lib_dir: lib_dir, header_dir: header_dir)

    assert_include(content, Shellwords.escape("-I#{header_dir}"))
    assert_include(content, Shellwords.escape("-Wl,-rpath,#{lib_dir}"))
    assert_include(content, Shellwords.escape("-L#{lib_dir}"))
  end
end
