# frozen_string_literal: true

require "mkmf"
require "shellwords"

module SwiftGem
  module Mkmf
    extend ::MakeMakefile

    DEFAULT_BUILDER = lambda do |package, source_dir|
      unless system("xcrun", "swift", "build", "-c", "release", "--package-path", source_dir)
        raise "swift build failed for package #{package.inspect}"
      end

      build_dir = File.expand_path(".build", source_dir)
      [File.join(build_dir, "release"), File.join(build_dir, "out/Intermediates.noindex/GeneratedModuleMaps")]
    end

    def self.create_swift_makefile(target, package:, source_dir:, builder: DEFAULT_BUILDER)
      lib_dir, header_dir = builder.call(package, source_dir)
      $CFLAGS << " #{Shellwords.escape("-I#{header_dir}")}"
      $LDFLAGS << " #{Shellwords.escape("-Wl,-rpath,#{lib_dir}")}" \
                  " #{Shellwords.escape("-L#{lib_dir}")}" \
                  " #{Shellwords.escape("-l#{package}")}"
      create_makefile(target)
    end
  end
end
