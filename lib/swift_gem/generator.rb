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
        if src.end_with?(".erb")
          File.write(dest_path, render(src_path, vars))
        else
          FileUtils.cp(src_path, dest_path)
        end
      end
    end

    private

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
