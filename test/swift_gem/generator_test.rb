# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "swift_gem/generator"

class SwiftGemGeneratorTest < Test::Unit::TestCase
  test "generates a complete swift gem skeleton from rb-foo-mac" do
    Dir.mktmpdir do |tmp|
      gem_dir = File.join(tmp, "rb-foo-mac")
      SwiftGem::Generator.new("rb-foo-mac").call(dest_dir: gem_dir)

      # core gem files
      assert_path_exists(File.join(gem_dir, "rb-foo-mac.gemspec"))
      assert_path_exists(File.join(gem_dir, "Gemfile"))
      assert_path_exists(File.join(gem_dir, "Rakefile"))
      assert_path_exists(File.join(gem_dir, "README.md"))
      assert_path_exists(File.join(gem_dir, ".gitignore"))
      assert_path_exists(File.join(gem_dir, "LICENSE.txt"))

      # lib
      assert_path_exists(File.join(gem_dir, "lib/foo_mac.rb"))
      assert_path_exists(File.join(gem_dir, "lib/foo_mac/version.rb"))

      # ext
      assert_path_exists(File.join(gem_dir, "ext/foo_mac/Package.swift"))
      assert_path_exists(File.join(gem_dir, "ext/foo_mac/Sources/FooMac/FooMac.swift"))
      assert_path_exists(File.join(gem_dir, "ext/foo_mac/Sources/FooMac/FooMacBridge.swift"))
      assert_path_exists(File.join(gem_dir, "ext/foo_mac/foo_mac.c"))
      assert_path_exists(File.join(gem_dir, "ext/foo_mac/foo_mac.h"))
      assert_path_exists(File.join(gem_dir, "ext/foo_mac/extconf.rb"))

      # CLIs
      assert_path_exists(File.join(gem_dir, "exe/foo-mac"))
      assert_path_exists(File.join(gem_dir, "examples/foo_mac.swift"))

      # tests
      assert_path_exists(File.join(gem_dir, "test/test_helper.rb"))

      # naming transforms inside generated files
      assert_match(/module FooMac/, File.read(File.join(gem_dir, "lib/foo_mac.rb")))
      assert_match(/spec\.name\s*=\s*["']rb-foo-mac["']/,
                   File.read(File.join(gem_dir, "rb-foo-mac.gemspec")))

      extconf = File.read(File.join(gem_dir, "ext/foo_mac/extconf.rb"))
      assert_match(/SwiftGem::Mkmf\.create_swift_makefile/, extconf)
      assert_match(/package:\s*["']FooMac["']/, extconf)
      assert_match(/source_dir:\s*__dir__/, extconf)

      # exe is executable
      assert(File.executable?(File.join(gem_dir, "exe/foo-mac")),
             "exe/foo-mac should be executable")
    end
  end

  test "module_name strips rb- prefix and CamelCases the rest" do
    assert_equal "FooMac",         SwiftGem::Generator.new("rb-foo-mac").module_name
    assert_equal "VisionOcrmac",   SwiftGem::Generator.new("rb-vision-ocrmac").module_name
    assert_equal "MySwiftGem",     SwiftGem::Generator.new("my_swift_gem").module_name
    assert_equal "SwiftPhotoTagger", SwiftGem::Generator.new("swift-photo-tagger").module_name
  end

  test "module_path strips rb- prefix and uses snake_case" do
    assert_equal "foo_mac",         SwiftGem::Generator.new("rb-foo-mac").module_path
    assert_equal "vision_ocrmac",   SwiftGem::Generator.new("rb-vision-ocrmac").module_path
    assert_equal "my_swift_gem",    SwiftGem::Generator.new("my_swift_gem").module_path
    assert_equal "swift_photo_tagger", SwiftGem::Generator.new("swift-photo-tagger").module_path
  end

  test "exe_name strips rb- prefix and keeps the gem-style separator" do
    assert_equal "foo-mac",          SwiftGem::Generator.new("rb-foo-mac").exe_name
    assert_equal "vision-ocrmac",    SwiftGem::Generator.new("rb-vision-ocrmac").exe_name
    assert_equal "my_swift_gem",     SwiftGem::Generator.new("my_swift_gem").exe_name
    assert_equal "swift-photo-tagger", SwiftGem::Generator.new("swift-photo-tagger").exe_name
  end
end
