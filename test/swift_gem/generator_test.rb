# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "swift_gem/generator"

class SwiftGemGeneratorTest < Test::Unit::TestCase
  def assert_file_exist(path)
    assert(File.exist?(path), "expected file to exist: #{path}")
  end

  test "generates a complete swift gem skeleton from rb-foo-mac" do
    Dir.mktmpdir do |tmp|
      gem_dir = File.join(tmp, "rb-foo-mac")
      SwiftGem::Generator.new("rb-foo-mac").call(dest_dir: gem_dir)

      # core gem files
      assert_file_exist(File.join(gem_dir, "rb-foo-mac.gemspec"))
      assert_file_exist(File.join(gem_dir, "Gemfile"))
      assert_file_exist(File.join(gem_dir, "Rakefile"))
      assert_file_exist(File.join(gem_dir, "README.md"))
      assert_file_exist(File.join(gem_dir, ".gitignore"))
      assert_file_exist(File.join(gem_dir, "LICENSE.txt"))
      assert_file_exist(File.join(gem_dir, ".bundle/config"))
      assert_match(/BUNDLE_PATH:\s*"vendor\/bundle"/,
                   File.read(File.join(gem_dir, ".bundle/config")))

      # lib
      assert_file_exist(File.join(gem_dir, "lib/foo_mac.rb"))
      assert_file_exist(File.join(gem_dir, "lib/foo_mac/version.rb"))

      # ext
      assert_file_exist(File.join(gem_dir, "ext/foo_mac/Package.swift"))
      assert_file_exist(File.join(gem_dir, "ext/foo_mac/Sources/FooMac/FooMac.swift"))
      assert_file_exist(File.join(gem_dir, "ext/foo_mac/Sources/FooMac/FooMacBridge.swift"))
      assert_file_exist(File.join(gem_dir, "ext/foo_mac/foo_mac.c"))
      assert_false(File.exist?(File.join(gem_dir, "ext/foo_mac/foo_mac.h")),
                   "hand-written .h should be removed; the C ext now includes the SPM-generated <Package>-Swift.h")
      assert_file_exist(File.join(gem_dir, "ext/foo_mac/extconf.rb"))

      # pure Swift sample (no Ruby CLI by default; see CLAUDE.md)
      assert_file_exist(File.join(gem_dir, "examples/foo_mac.swift"))
      assert_false(File.exist?(File.join(gem_dir, "exe")),
                   "generator should not scaffold a Ruby CLI under exe/")

      # tests
      assert_file_exist(File.join(gem_dir, "test/test_helper.rb"))

      # swiftly toolchain pin: cd alone honors .swift-version via swiftly's shim
      swift_version_path = File.join(gem_dir, ".swift-version")
      assert_file_exist(swift_version_path)
      assert_match(/\A6\.\d+(?:\.\d+)?\s*\z/, File.read(swift_version_path),
                   ".swift-version should pin a Swift 6.x toolchain (SE-0495 requires 6.3+)")
      # The pin must derive from SwiftVersionCheck::MINIMUM so the version-check
      # error path and the generated scaffold cannot drift apart.
      require "swift_gem/swift_version_check"
      assert_equal SwiftGem::SwiftVersionCheck::MINIMUM.to_s,
                   File.read(swift_version_path).strip,
                   ".swift-version must equal SwiftVersionCheck::MINIMUM"

      # naming transforms inside generated files
      assert_match(/module FooMac/, File.read(File.join(gem_dir, "lib/foo_mac.rb")))
      assert_match(/spec\.name\s*=\s*["']rb-foo-mac["']/,
                   File.read(File.join(gem_dir, "rb-foo-mac.gemspec")))

      extconf = File.read(File.join(gem_dir, "ext/foo_mac/extconf.rb"))
      assert_match(/SwiftGem::Mkmf\.create_swift_makefile/, extconf)
      assert_match(/package:\s*["']FooMac["']/, extconf)
      assert_match(/source_dir:\s*__dir__/, extconf)

      bridge = File.read(File.join(gem_dir, "ext/foo_mac/Sources/FooMac/FooMacBridge.swift"))
      assert_match(/^@c\npublic func foo_mac_perform/, bridge,
                   "Bridge should use the SE-0495 @c attribute (bare form; Swift function name doubles as the C symbol)")
      assert_match(/^@c\npublic func foo_mac_free/, bridge,
                   "Bridge should use the SE-0495 @c attribute")
      assert_not_match(/@_cdecl/, bridge,
                       "Bridge should not use the experimental @_cdecl after Swift 6.3 migration")
      assert_not_match(/@c\([^)]*"/, bridge,
                       "@c does not accept a string literal; pass a bare C identifier or omit the argument")

      package = File.read(File.join(gem_dir, "ext/foo_mac/Package.swift"))
      assert_match(/swift-tools-version:\s*6\.3/, package,
                   "Package.swift should declare swift-tools-version 6.3 (SE-0495 requires Swift 6.3)")

      ext_c = File.read(File.join(gem_dir, "ext/foo_mac/foo_mac.c"))
      assert_match(/#include\s+"FooMac-Swift\.h"/, ext_c,
                   "C ext should include the auto-generated <Package>-Swift.h emitted by 'swift build -emit-clang-header-path'")
      assert_not_match(/#include\s+"foo_mac\.h"/, ext_c,
                       "C ext should not reference the removed hand-written header")
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
