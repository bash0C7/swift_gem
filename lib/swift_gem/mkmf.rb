# frozen_string_literal: true

require "mkmf"
require "swift_gem/swift_version_check"

module SwiftGem
  module Mkmf
    extend ::MakeMakefile

    DEFAULT_BUILDER = lambda do |package, source_dir|
      unless system("swift", "build", "-c", "release", "--package-path", source_dir)
        raise "swift build failed for package #{package.inspect}"
      end
      File.expand_path(".build/release", source_dir)
    end

    def self.create_swift_makefile(target, package:, source_dir:, builder: DEFAULT_BUILDER,
                                   swift_version_probe: SwiftVersionCheck.method(:default_probe))
      SwiftVersionCheck.call!(prober: swift_version_probe)
      lib_dir = builder.call(package, source_dir)
      $LDFLAGS << " -Wl,-rpath,#{lib_dir} -L#{lib_dir} -l#{package}"
      create_makefile(target)
    end
  end
end
