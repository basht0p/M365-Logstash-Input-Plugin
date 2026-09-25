# frozen_string_literal: true

require 'json'

module LogStash
  module Inputs
    module Microsoft365Support
      class Manifest
        PATH = ::File.expand_path('../../../../data/collector_manifest.json', __dir__)

        def self.load
          @manifest ||= begin
            parsed = JSON.parse(::File.read(PATH))
            raise 'Unsupported collector manifest schema' unless parsed.fetch('schema_version') == 1
            parsed.freeze
          end
        end

        def self.cloud(name)
          load.fetch('clouds').fetch(name)
        end

        def self.collector(name)
          load.fetch('collectors').fetch(name)
        end
      end
    end
  end
end
