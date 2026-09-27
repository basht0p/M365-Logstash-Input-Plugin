# frozen_string_literal: true

module LogStash
  module Inputs
    module Microsoft365Support
      # A queue write was abandoned because the input is stopping; source progress was not committed.
      class QueueStopped < StandardError; end

      # Collection was abandoned because the input is stopping.
      class Stopped < StandardError; end

      # Source records became unavailable before they could be collected. Progress continues past the gap.
      class SourceGap < StandardError; end

      # A window needed more pages than the per-window budget. Callers split the window and retry.
      class WindowTooLarge < StandardError; end

      # Some independent parts of a collector failed while the others completed.
      class PartialFailure < StandardError
        attr_reader :failures

        def initialize(collector, failures)
          @failures = failures
          details = failures.map { |part, error| "#{part}: #{Errors.safe_message(error)}" }.join('; ')
          super("#{collector} partially failed: #{details}")
        end
      end

      module Errors
        # Messages of these errors describe the source request, never secrets or record contents. Plain
        # RuntimeErrors are raised only by this plugin's own validation messages.
        SAFE_MESSAGE_CLASSES = %w[HTTPError ResponseTooLarge SourceGap WindowTooLarge PartialFailure RuntimeError].freeze

        def self.safe_message(error)
          SAFE_MESSAGE_CLASSES.include?(error.class.name.split('::').last) ? error.message : error.class.name
        end

        def self.pausing_http_error?(error)
          error.class.name.end_with?('::HTTPError') && [400, 401, 403, 404].include?(error.status)
        end
      end
    end
  end
end
