# frozen_string_literal: true

require "erb"
require "fileutils"
require_relative "swift_version_check"

module SwiftGem
  class Generator
    TEMPLATE_DIR = File.expand_path("templates", __dir__)

    TEMPLATES = [
      ["gemspec.erb",            "%{gem_name}.gemspec"],
      ["Gemfile.erb",            "Gemfile"],
      ["Rakefile.erb",           "Rakefile"],
      ["README.md.erb",          "README.md"],
      ["gitignore",              ".gitignore"],
      ["bundle_config",          ".bundle/config"],
      ["swift_version.erb",      ".swift-version"],
      ["LICENSE.txt",            "LICENSE.txt"],
      ["lib_main.rb.erb",        "lib/%{module_path}.rb"],
      ["lib_version.rb.erb",     "lib/%{module_path}/version.rb"],
      ["ext_Package.swift.erb",  "ext/%{module_path}/Package.swift"],
      ["ext_Sources.swift.erb",  "ext/%{module_path}/Sources/%{module_name}/%{module_name}.swift"],
      ["ext_Bridge.swift.erb",   "ext/%{module_path}/Sources/%{module_name}/%{module_name}Bridge.swift"],
      ["ext_main.c.erb",         "ext/%{module_path}/%{module_path}.c"],
      ["ext_extconf.rb.erb",     "ext/%{module_path}/extconf.rb"],
      ["examples_cli.swift.erb", "examples/%{module_path}.swift"],
      ["test_helper.rb.erb",     "test/test_helper.rb"],
      ["test_sample.rb.erb",     "test/%{module_path}/sample_test.rb"]
    ].freeze

    # Build-time helpers vendored into each generated gem's ext dir, sourced
    # from this gem's own lib/ (single source of truth). rubygems' extension
    # builder spawns a plain `ruby extconf.rb` outside bundler's load-path
    # setup, where a git:/path: swift_gem is invisible — so the generated gem
    # must carry its build helper in-tree instead of `require`-ing swift_gem.
    # Maps a lib/swift_gem/<source> to its vendored ext destination.
    VENDORED_BUILD_HELPERS = [
      ["swift_version_check.rb", "ext/%{module_path}/swift_version_check.rb"],
      ["mkmf.rb",                "ext/%{module_path}/swift_mkmf.rb"]
    ].freeze

    attr_reader :gem_name

    def initialize(gem_name)
      @gem_name = gem_name
    end

    def module_name
      parts = @gem_name.split(/[-_]/)
      parts.shift if parts.first == "rb"
      parts.map { |p| p.sub(/^./) { |c| c.upcase } }.join
    end

    def module_path
      @gem_name.sub(/^rb[-_]/, "").tr("-", "_")
    end

    def exe_name
      @gem_name.sub(/^rb[-_]/, "")
    end

    def call(dest_dir:)
      FileUtils.mkdir_p(dest_dir)
      vars = template_vars

      TEMPLATES.each do |src, dest_template|
        dest_rel = format(dest_template, vars)
        dest_path = File.join(dest_dir, dest_rel)
        FileUtils.mkdir_p(File.dirname(dest_path))

        src_path = File.join(TEMPLATE_DIR, src)
        # Templates without .erb are copied verbatim; .erb templates render with ERB.
        if src.end_with?(".erb")
          File.write(dest_path, render(src_path, vars))
        else
          FileUtils.cp(src_path, dest_path)
        end
      end

      VENDORED_BUILD_HELPERS.each do |src, dest_template|
        dest_path = File.join(dest_dir, format(dest_template, vars))
        FileUtils.mkdir_p(File.dirname(dest_path))
        File.write(dest_path, vendored_helper_source(src))
      end
    end

    private

    # Reads a build helper from this gem's lib/ and localizes its cross-file
    # require so the vendored copy is self-contained (depends on nothing from
    # the swift_gem gem at extension-build time).
    def vendored_helper_source(filename)
      source = File.read(File.expand_path(filename, __dir__))
      source
        .sub(/\A# frozen_string_literal: true\n/,
             "# frozen_string_literal: true\n#\n" \
             "# Vendored from the swift_gem scaffold; do not edit by hand.\n" \
             "# The extension must build without swift_gem on the load path.\n")
        .gsub('require "swift_gem/swift_version_check"',
              'require_relative "swift_version_check"')
    end

    def template_vars
      {
        gem_name: @gem_name,
        module_name: module_name,
        module_path: module_path,
        exe_name: exe_name,
        c_symbol_prefix: "#{module_path}_",
        swift_minimum: SwiftVersionCheck::MINIMUM.to_s
      }
    end

    def render(template_path, vars)
      tmpl = File.read(template_path)
      erb = ERB.new(tmpl, trim_mode: "-")
      ctx = Context.new(**vars)
      erb.result(ctx.__binding__)
    end

    class Context
      def initialize(**vars)
        vars.each { |key, value| define_singleton_method(key) { value } }
      end

      def __binding__
        binding
      end
    end
  end
end
