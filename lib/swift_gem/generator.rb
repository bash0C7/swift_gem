# frozen_string_literal: true

require "erb"
require "fileutils"

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
      ["LICENSE.txt",            "LICENSE.txt"],
      ["lib_main.rb.erb",        "lib/%{module_path}.rb"],
      ["lib_version.rb.erb",     "lib/%{module_path}/version.rb"],
      ["sig_main.rbs.erb",       "sig/%{module_path}.rbs"],
      ["ext_Package.swift.erb",  "ext/%{module_path}/Package.swift"],
      ["ext_Sources.swift.erb",  "ext/%{module_path}/Sources/%{module_name}/%{module_name}.swift"],
      ["ext_Bridge.swift.erb",   "ext/%{module_path}/Sources/%{module_name}/%{module_name}Bridge.swift"],
      ["ext_main.c.erb",         "ext/%{module_path}/%{module_path}.c"],
      ["ext_extconf.rb.erb",     "ext/%{module_path}/extconf.rb"],
      ["examples_cli.swift.erb", "examples/%{module_path}.swift"],
      ["test_helper.rb.erb",     "test/test_helper.rb"],
      ["test_sample.rb.erb",     "test/%{module_path}/sample_test.rb"]
    ].freeze

    VENDORED_BUILD_HELPERS = [
      ["mkmf.rb", "ext/%{module_path}/swift_mkmf.rb"]
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

    def call(dest_dir:)
      vars = template_vars

      TEMPLATES.each do |src, dest_template|
        dest_path = File.join(dest_dir, format(dest_template, vars))
        FileUtils.mkdir_p(File.dirname(dest_path))

        src_path = File.join(TEMPLATE_DIR, src)
        if src.end_with?(".erb")
          File.write(dest_path, ERB.new(File.read(src_path), trim_mode: "-").result_with_hash(vars))
        else
          FileUtils.cp(src_path, dest_path)
        end
      end

      VENDORED_BUILD_HELPERS.each do |src, dest_template|
        dest_path = File.join(dest_dir, format(dest_template, vars))
        FileUtils.mkdir_p(File.dirname(dest_path))
        File.write(dest_path, File.read(File.expand_path(src, __dir__)))
      end
    end

    private

    def template_vars
      {
        gem_name: @gem_name,
        module_name: module_name,
        module_path: module_path,
        c_symbol_prefix: "#{module_path}_"
      }
    end
  end
end
