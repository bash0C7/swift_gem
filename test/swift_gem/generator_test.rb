# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "swift_gem/generator"

class SwiftGemGeneratorTest < Test::Unit::TestCase
  RUBY_COMMENT = /^\s*#(?! frozen_string_literal: true$)/
  SLASH_COMMENT = %r{^\s*//(?!/|\s*swift-tools-version:)}

  def generate(&block)
    Dir.mktmpdir do |tmp|
      gem_dir = File.join(tmp, "rb-foo-mac")
      SwiftGem::Generator.new("rb-foo-mac").call(dest_dir: gem_dir)
      block.call(gem_dir)
    end
  end

  def read(gem_dir, path)
    File.read(File.join(gem_dir, path))
  end

  test "generates the expected file list from rb-foo-mac" do
    generate do |gem_dir|
      expected = %w[
        rb-foo-mac.gemspec
        Gemfile
        Rakefile
        README.md
        .gitignore
        .bundle/config
        LICENSE.txt
        lib/foo_mac.rb
        lib/foo_mac/version.rb
        sig/foo_mac.rbs
        ext/foo_mac/Package.swift
        ext/foo_mac/Sources/FooMac/FooMac.swift
        ext/foo_mac/Sources/FooMac/FooMacBridge.swift
        ext/foo_mac/foo_mac.c
        ext/foo_mac/extconf.rb
        ext/foo_mac/swift_mkmf.rb
        examples/foo_mac.swift
        test/test_helper.rb
        test/foo_mac/sample_test.rb
      ]
      actual = Dir.glob("**/*", File::FNM_DOTMATCH, base: gem_dir).select { |f| File.file?(File.join(gem_dir, f)) }
      assert_equal(expected.sort, actual.sort)
      assert_match(/BUNDLE_PATH:\s*"vendor\/bundle"/, read(gem_dir, ".bundle/config"))
    end
  end

  test "fills in naming transforms and the Swift 6.4 / macOS 27 manifest" do
    generate do |gem_dir|
      assert_match(/module FooMac/, read(gem_dir, "lib/foo_mac.rb"))
      assert_match(/spec\.name\s*=\s*["']rb-foo-mac["']/, read(gem_dir, "rb-foo-mac.gemspec"))
      assert_match(/required_ruby_version\s*=\s*">= 4\.0"/, read(gem_dir, "rb-foo-mac.gemspec"))

      package = read(gem_dir, "ext/foo_mac/Package.swift")
      assert_match(/^\/\/ swift-tools-version: 6\.4$/, package)
      assert_include(package, "platforms: [.macOS(.v27)]")

      extconf = read(gem_dir, "ext/foo_mac/extconf.rb")
      assert_match(/SwiftGem::Mkmf\.create_swift_makefile/, extconf)
      assert_match(/package:\s*["']FooMac["']/, extconf)
      assert_match(/source_dir:\s*__dir__/, extconf)

      assert_match(/#include\s+"FooMac-Swift\.h"/, read(gem_dir, "ext/foo_mac/foo_mac.c"))
    end
  end

  test "bridge names the C symbols with @c" do
    generate do |gem_dir|
      bridge = read(gem_dir, "ext/foo_mac/Sources/FooMac/FooMacBridge.swift")
      assert_match(/^@c\(foo_mac_perform\)\npublic func cPerform/, bridge)
      assert_match(/^@c\(foo_mac_free\)\npublic func cFree/, bridge)
      assert_not_match(/@_cdecl/, bridge)
      assert_match(/^func perform\(_ input: String\) -> String/, read(gem_dir, "ext/foo_mac/Sources/FooMac/FooMac.swift"))
    end
  end

  test "generated Rakefile makes compile depend on swift before the extension task is declared" do
    generate do |gem_dir|
      rakefile = read(gem_dir, "Rakefile")
      assert_operator(rakefile.index("task compile: :swift"), :<, rakefile.index("Rake::ExtensionTask.new"))
    end
  end

  test "generated gem validates its RBS signatures before testing" do
    generate do |gem_dir|
      assert_match(/gem "rbs"/, read(gem_dir, "Gemfile"))
      rakefile = read(gem_dir, "Rakefile")
      assert_include(rakefile, 'sh "rbs", "-I", "sig", "validate"')
      assert_include(rakefile, "task test: %i[rbs compile]")
    end
  end

  test "ships an RBS signature for the generated module" do
    generate do |gem_dir|
      sig = read(gem_dir, "sig/foo_mac.rbs")
      assert_match(/^module FooMac$/, sig)
      assert_include(sig, "VERSION: String")
      assert_include(sig, "def self.perform: (String input) -> String")
    end
  end

  test "vendors only swift_mkmf.rb and requires it relatively" do
    generate do |gem_dir|
      assert_equal(File.read(File.expand_path("../../lib/swift_gem/mkmf.rb", __dir__)),
                   read(gem_dir, "ext/foo_mac/swift_mkmf.rb"))
      assert_match(/require_relative\s+["']swift_mkmf["']/, read(gem_dir, "ext/foo_mac/extconf.rb"))
      assert_not_match(/require\s+["']swift_gem/, read(gem_dir, "ext/foo_mac/extconf.rb"))
      assert_not_match(%r{swift_gem/}, read(gem_dir, "ext/foo_mac/swift_mkmf.rb"))
    end
  end

  test "generated gem does not depend on swift_gem" do
    generate do |gem_dir|
      assert_not_match(/swift_gem/, read(gem_dir, "Gemfile"))
      assert_not_match(/add_dependency\s+["']swift_gem["']/, read(gem_dir, "rb-foo-mac.gemspec"))
    end
  end

  test "generated Ruby, Swift and C files carry no ordinary comment lines" do
    generate do |gem_dir|
      ruby_files = Dir.glob("**/*.rb", base: gem_dir) + %w[Gemfile Rakefile rb-foo-mac.gemspec .gitignore]
      ruby_files.each do |f|
        assert_not_match(RUBY_COMMENT, read(gem_dir, f), "ordinary comment in #{f}")
      end

      (Dir.glob("**/*.swift", base: gem_dir) + Dir.glob("**/*.c", base: gem_dir)).each do |f|
        assert_not_match(SLASH_COMMENT, read(gem_dir, f), "ordinary comment in #{f}")
      end
    end
  end

  test "the emitted .gitignore does not drop the tracked .bundle/config" do
    generate do |gem_dir|
      Dir.chdir(gem_dir) do
        system("git", "init", "-q", "-b", "main", out: File::NULL, err: File::NULL)
        system("git", "add", "-A", out: File::NULL, err: File::NULL)
        assert_include(`git ls-files`.split("\n"), ".bundle/config")
      end
    end
  end

  test "module_name strips rb- prefix and CamelCases the rest" do
    assert_equal "FooMac",           SwiftGem::Generator.new("rb-foo-mac").module_name
    assert_equal "VisionOcrmac",     SwiftGem::Generator.new("rb-vision-ocrmac").module_name
    assert_equal "MySwiftGem",       SwiftGem::Generator.new("my_swift_gem").module_name
    assert_equal "SwiftPhotoTagger", SwiftGem::Generator.new("swift-photo-tagger").module_name
  end

  test "module_path strips rb- prefix and uses snake_case" do
    assert_equal "foo_mac",            SwiftGem::Generator.new("rb-foo-mac").module_path
    assert_equal "vision_ocrmac",      SwiftGem::Generator.new("rb-vision-ocrmac").module_path
    assert_equal "my_swift_gem",       SwiftGem::Generator.new("my_swift_gem").module_path
    assert_equal "swift_photo_tagger", SwiftGem::Generator.new("swift-photo-tagger").module_path
  end
end
