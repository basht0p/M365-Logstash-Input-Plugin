# frozen_string_literal: true

require 'json'
require 'time'
require 'uri'
require 'digest'
require_relative 'manifest'
require_relative 'errors'
require_relative 'windows'

module LogStash
  module Inputs
    module Microsoft365Support
      class GraphCollector
        MAX_PAGES = 1000
        MAX_WINDOW = 3600
        DEFAULT_PAGE_SIZE = 100

        def initialize(name:, http:, state:, emitter:, config:, stop:, clock: -> { Time.now.utc }, max_pages: MAX_PAGES)
          @name, @http, @state, @emitter, @config, @stop, @clock = name, http, state, emitter, config, stop, clock
          @max_pages = max_pages
          @spec = Manifest.collector(name)
          @windows = TimeWindows.new(state: state, config: config, clock: clock, max_window: MAX_WINDOW)
        end

        def run_once
          return reconcile_all if @spec.fetch('strategy') == 'full_reconcile'

          signin_types = @name == 'signin_beta' ? @config.fetch(:signin_types) : [nil]
          signin_types.each do |type|
            prefix = "#{@name}:#{type || 'default'}"
            @windows.advance("#{prefix}:window") { |start_at, finish_at, force| fetch_window(start_at, finish_at, type, force: force) }
            @windows.reconcile("#{prefix}:reconcile") { |start_at, finish_at| fetch_window(start_at, finish_at, type) }
          end
        end

        private

        # Lists the whole collection. Dedupe entries of unchanged records are refreshed so they don't
        # expire while the source still returns them.
        def reconcile_all
          fetch_pages(url_for(nil, nil)) do |record|
            emit(record, mutable: true, refresh: true)
          end
          @state.set_checkpoint("#{@name}:reconciled", @clock.call.utc.iso8601(3))
        rescue WindowTooLarge => e
          raise "#{e.message}; #{@name} lists its whole collection and cannot split it"
        end

        def fetch_window(start_at, finish_at, signin_type = nil, force: false)
          fetch_pages(url_for(start_at, finish_at, signin_type)) do |record|
            emit(record, mutable: mutable?, collector_name: signin_type ? "signin_beta.#{signin_type}" : @name, force: force)
          end
        end

        def mutable?
          %w[defender_alert defender_incident].include?(@name)
        end

        def url_for(start_at, finish_at, signin_type = nil)
          url = "/#{@spec.fetch('api_version')}#{@spec.fetch('endpoint')}"
          query = { '$top' => @spec.fetch('page_size', DEFAULT_PAGE_SIZE) }
          if start_at
            field = @spec.fetch('timestamp_field')
            filter = "#{field} ge #{start_at.iso8601(3)} and #{field} le #{finish_at.iso8601(3)}"
            filter += " and signInEventTypes/any(t: t eq '#{signin_type}')" if signin_type
            query = { '$filter' => filter }.merge(query)
          end
          "#{url}?#{URI.encode_www_form(query)}"
        end

        def fetch_pages(first_url)
          url = first_url
          visited = {}
          pages = 0
          while url
            raise Stopped, 'Microsoft 365 collection stopped' if @stop.call
            raise "Repeated Graph nextLink for #{@name}" if visited[url]
            raise WindowTooLarge, "#{@name} needed more than #{@max_pages} pages" if pages >= @max_pages

            visited[url] = true
            response = @http.get('graph', url)
            data = response.body
            raise "Invalid Graph response for #{@name}" unless data.is_a?(Hash) && data['value'].is_a?(Array)

            data['value'].each { |record| yield record }
            url = data['@odata.nextLink']
            pages += 1
          end
        end

        def emit(record, mutable: false, collector_name: @name, force: false, refresh: false)
          id = record.fetch('id')
          timestamp = record[@spec.fetch('timestamp_field')]
          @emitter.emit(collector: collector_name, raw: record, identity: id, timestamp: timestamp, mutable: mutable,
                        force: force, refresh: refresh)
        end
      end

      class ActivityCollector
        MAX_PAGES = 1000
        MAX_WINDOW = 86_400
        # The Management API serves content from the last seven days; keep a margin for clock skew.
        MAX_AGE = 7 * 86_400 - 900
        FAILURE_BACKOFF = 3600
        FORCE_FIELD = '_m365_force'

        def initialize(http:, state:, emitter:, config:, stop:, clock: -> { Time.now.utc }, max_pages: MAX_PAGES)
          @http, @state, @emitter, @config, @stop, @clock = http, state, emitter, config, stop, clock
          @max_pages = max_pages
          @tenant_id = config.fetch(:tenant_id)
          @windows = TimeWindows.new(state: state, config: config, clock: clock, max_window: MAX_WINDOW, max_age: MAX_AGE)
          @retry_at = {}
          @gaps = []
        end

        # Content types are collected independently: one failing or paused type does not block the others.
        def run_once
          @gaps = []
          failures = {}
          @config.fetch(:activity_content_types).each do |type|
            next if @retry_at[type] && @clock.call.utc < @retry_at[type]

            begin
              collect(type)
              @retry_at.delete(type)
            rescue QueueStopped, Stopped
              raise
            rescue StandardError => e
              @retry_at[type] = @clock.call.utc + FAILURE_BACKOFF if Errors.pausing_http_error?(e)
              failures[type] = e
            end
          end
          raise PartialFailure.new('activity', failures) unless failures.empty?
          raise SourceGap, "Activity source gaps: #{@gaps.join('; ')}" unless @gaps.empty?
        end

        private

        def collect(type)
          return unless ensure_subscription(type)

          drain_pending(type)
          gap = @windows.advance("activity:#{type}:window") do |start_at, finish_at, force|
            fetch_content_window(type, start_at, finish_at, force: force)
          end
          @gaps << "#{type} discovery skipped #{gap}" if gap
          @windows.reconcile("activity:#{type}:reconcile") do |start_at, finish_at|
            fetch_content_window(type, start_at, finish_at)
          end
        end

        def base_path
          "/api/v1.0/#{@tenant_id}/activity/feed/subscriptions"
        end

        def publisher_query
          value = @config[:publisher_identifier]
          value && !value.empty? ? "&PublisherIdentifier=#{URI.encode_www_form_component(value)}" : ''
        end

        def ensure_subscription(type)
          response = @http.get('activity', "#{base_path}/list?#{publisher_query.sub(/^&/, '')}")
          subscriptions = response.body
          raise 'Invalid Activity subscription response' unless subscriptions.is_a?(Array)

          existing = subscriptions.find { |item| item['contentType'] == type }
          return true if existing && existing['status'].to_s.casecmp('enabled').zero?
          raise "Activity subscription #{type} exists but is disabled; inspect tenant webhook settings" if existing

          last_start = @state.checkpoint("activity:#{type}:subscription_start")
          return false if last_start && @clock.call.utc - Time.iso8601(last_start) < 900

          @http.post('activity', "#{base_path}/start?contentType=#{URI.encode_www_form_component(type)}#{publisher_query}", {})
          @state.set_checkpoint("activity:#{type}:subscription_start", @clock.call.utc.iso8601(3))
          false
        end

        def fetch_content_window(type, start_at, finish_at, force: false)
          url = "#{base_path}/content?contentType=#{URI.encode_www_form_component(type)}&startTime=#{URI.encode_www_form_component(start_at.iso8601)}&endTime=#{URI.encode_www_form_component(finish_at.iso8601)}#{publisher_query}"
          visited = {}
          pages = 0
          while url
            raise Stopped, 'Microsoft 365 collection stopped' if @stop.call
            raise "Repeated Activity NextPageUri for #{type}" if visited[url]
            raise WindowTooLarge, "Activity #{type} needed more than #{@max_pages} pages" if pages >= @max_pages

            visited[url] = true
            response = @http.get('activity', url)
            raise "Invalid Activity discovery response for #{type}" unless response.body.is_a?(Array)

            response.body.each do |blob|
              id = blob.fetch('contentId')
              if force
                @state.add_pending("activity:#{type}", id, blob.merge(FORCE_FIELD => true))
              elsif !@state.seen?("activity:#{type}:blob", id, 'done')
                @state.add_pending("activity:#{type}", id, blob)
              end
            end
            drain_pending(type)
            url = response.headers['nextpageuri'] || response.headers['NextPageUri']
            pages += 1
          end
        end

        def drain_pending(type)
          @state.pending("activity:#{type}").each do |id_hash, blob|
            raise Stopped, 'Microsoft 365 collection stopped' if @stop.call

            content_id = blob.fetch('contentId')
            if blob['contentExpiration'] && Time.iso8601(blob['contentExpiration']) < @clock.call.utc
              # The API no longer serves this blob. Record the gap once and move on rather than retrying forever.
              @gaps << "#{type} blob #{content_id} expired at #{blob['contentExpiration']} before download"
              @state.mark_seen("activity:#{type}:blob", content_id, 'done')
              @state.remove_pending_hash("activity:#{type}", id_hash)
              next
            end
            records = @http.get('activity', blob.fetch('contentUri')).body
            raise "Invalid Activity blob #{content_id}" unless records.is_a?(Array)

            records.each do |record|
              identity = record['Id'] || record['id'] || Digest::SHA256.hexdigest(JSON.generate(record))
              timestamp = record['CreationTime'] || record['creationTime']
              @emitter.emit(collector: "activity.#{type}", raw: record, identity: identity, timestamp: timestamp,
                            force: blob[FORCE_FIELD] == true)
            end
            @state.mark_seen("activity:#{type}:blob", content_id, 'done')
            @state.remove_pending_hash("activity:#{type}", id_hash)
          end
        end
      end
    end
  end
end
