# frozen_string_literal: true

module LogStash
  module Inputs
    module Microsoft365Support
      module Jars
        def self.load!
          return if @loaded
          raise 'Java dependencies require JRuby' unless defined?(JRUBY_VERSION)
          root = ::File.expand_path('../../../../vendor/jars', __dir__)
          jars = Dir[::File.join(root, '*.jar')]
          raise "Microsoft 365 Java dependencies missing from #{root}" if jars.empty?
          jars.sort.each { |jar| require jar }
          @loaded = true
        end
      end
    end
  end
end
