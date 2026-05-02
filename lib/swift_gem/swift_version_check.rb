# frozen_string_literal: true

require "rubygems"

module SwiftGem
  module SwiftVersionCheck
    MINIMUM = Gem::Version.new("6.3")

    class IncompatibleSwiftVersion < StandardError; end

    module_function

    def call!(prober: method(:default_probe))
      output = prober.call
      version = parse(output)
      if version.nil?
        raise IncompatibleSwiftVersion,
              "swift_gem: cannot parse swift toolchain version from: #{output.inspect}. " \
              "Install Swift 6.3+ via swiftly: 'brew install swiftly && swiftly install 6.3 && swiftly use 6.3'."
      end
      if version < MINIMUM
        raise IncompatibleSwiftVersion,
              "swift_gem: requires Swift #{MINIMUM}+ (found #{version}). " \
              "Upgrade via swiftly: 'swiftly install 6.3 && swiftly use 6.3'."
      end
      version
    end

    def parse(output)
      match = output.match(/Apple Swift version (\d+\.\d+(?:\.\d+)?)/)
      match && Gem::Version.new(match[1])
    end

    def default_probe
      `swift --version 2>&1`
    end
  end
end
