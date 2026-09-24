# frozen_string_literal: true

require 'json'
require 'time'
require 'uri'
require 'digest'
require_relative 'manifest'

module LogStash
  module Inputs
    module Microsoft365Support
      class GraphCollector
        MAX_PAGES = 1000
        MAX_WINDOW = 3600

        def initialize(name:, http:, state:, emitter:, config:, stop:, clock: -> { Time.now.utc })
          @name, @http, @state, @emitter, @config, @stop, @clock = name, http, state, emitter, config, stop, clock
          @spec = Manifest.collector(name)
        end

        def run_once
          return reconcile if @spec.fetch('strategy') == 'full_reconcile'
          if @name == 'signin_beta'
            @config.fetch(:signin_types).each do |type|
              run_window(type)
              reconcile_window(type)
            end
          else
            run_window
            reconcile_window
          end
        end

        def run_window(signin_type = nil)
          key = "#{@name}:#{signin_type || 'default'}:window"
          now = @clock.call.utc
          previous = @state.checkpoint(key)
          start_at = previous ? Time.iso8601(previous) - @config.fetch(:overlap) : now - @config.fetch(:initial_lookback)
          replay_from = @config[:replay_from]
          if replay_from
            replay_key = "#{key}:replay:#{replay_from}"
            start_at = [start_at, Time.iso8601(replay_from)].min unless @state.checkpoint(replay_key)
          end
          finish_at = [start_at + MAX_WINDOW, now].min
          return if finish_at <= start_at

          fetch_window(start_at, finish_at, signin_type)
          @state.set_checkpoint(key, finish_at.iso8601(3))
          @state.set_checkpoint(replay_key, 'done') if replay_from && replay_key
        end

        private

        def reconcile_window(signin_type = nil)
          group = "#{@name}:#{signin_type || 'default'}:reconcile"
          now = @clock.call.utc
          last_started = @state.checkpoint("#{group}:last_started")
          cursor_text = @state.checkpoint("#{group}:cursor")
          target_text = @state.checkpoint("#{group}:target")
          if !cursor_text || cursor_text.empty?
            return if last_started && now - Time.iso8601(last_started) < @config.fetch(:reconciliation_interval)
            @state.set_checkpoint("#{group}:target", now.iso8601(3))
            target_text = now.iso8601(3)
            start_at = now - @config.fetch(:replay_horizon)
            @state.set_checkpoint("#{group}:cursor", start_at.iso8601(3))
            @state.set_checkpoint("#{group}:last_started", now.iso8601(3))
          else
            start_at = Time.iso8601(cursor_text)
          end
          target = target_text && !target_text.empty? ? Time.iso8601(target_text) : now
          finish_at = [start_at + MAX_WINDOW, target].min
          return if finish_at <= start_at
          fetch_window(start_at, finish_at, signin_type)
          @state.set_checkpoint("#{group}:cursor", finish_at >= target ? '' : finish_at.iso8601(3))
        end

        def reconcile
          fetch_pages(url_for(nil, nil)) do |record|
            emit(record, mutable: true)
          end
          @state.set_checkpoint("#{@name}:reconciled", @clock.call.utc.iso8601(3))
        end

        def fetch_window(start_at, finish_at, signin_type = nil)
          fetch_pages(url_for(start_at, finish_at, signin_type)) do |record|
            emit(record, mutable: mutable?, collector_name: signin_type ? "signin_beta.#{signin_type}" : @name)
          end
        end

        def mutable?
          %w[defender_alert defender_incident].include?(@name)
        end

        def url_for(start_at, finish_at, signin_type = nil)
          version = @spec.fetch('api_version')
          endpoint = @spec.fetch('endpoint')
          url = "/#{version}#{endpoint}"
          return url if start_at.nil?

          field = @spec.fetch('timestamp_field')
          filter = "#{field} ge #{start_at.iso8601(3)} and #{field} le #{finish_at.iso8601(3)}"
          filter += " and signInEventTypes/any(t: t eq '#{signin_type}')" if signin_type
          "#{url}?#{URI.encode_www_form('$filter' => filter, '$top' => 100)}"
        end

        def fetch_pages(first_url)
          url = first_url
          visited = {}
          pages = 0
          while url
            raise 'Microsoft 365 collection stopped' if @stop.call
            raise "Repeated Graph nextLink for #{@name}" if visited[url]
            raise "Graph pagination limit exceeded for #{@name}" if pages >= MAX_PAGES
            visited[url] = true
            response = @http.get('graph', url)
            data = response.body
            raise "Invalid Graph response for #{@name}" unless data.is_a?(Hash) && data['value'].is_a?(Array)
            data['value'].each { |record| yield record }
            url = data['@odata.nextLink']
            pages += 1
          end
        end

        def emit(record, mutable: false, collector_name: @name)
          id = record.fetch('id')
          timestamp = record[@spec.fetch('timestamp_field')]
          @emitter.emit(collector: collector_name, raw: record, identity: id, timestamp: timestamp, mutable: mutable)
        end
      end

      class ActivityCollector
        MAX_PAGES = 1000
        MAX_WINDOW = 86_400

        def initialize(http:, state:, emitter:, config:, stop:, clock: -> { Time.now.utc })
          @http, @state, @emitter, @config, @stop, @clock = http, state, emitter, config, stop, clock
          @tenant_id = config.fetch(:tenant_id)
        end

        def run_once
          @config.fetch(:activity_content_types).each do |type|
            next unless ensure_subscription(type)
            drain_pending(type)
            discover(type)
            reconcile(type)
          end
        end

        private

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

        def discover(type)
          key = "activity:#{type}:window"
          now = @clock.call.utc
          previous = @state.checkpoint(key)
          start_at = previous ? Time.iso8601(previous) - @config.fetch(:overlap) : now - @config.fetch(:initial_lookback)
          replay_from = @config[:replay_from]
          if replay_from
            replay_key = "#{key}:replay:#{replay_from}"
            start_at = [start_at, Time.iso8601(replay_from)].min unless @state.checkpoint(replay_key)
          end
          raise "Activity availability gap for #{type}: discovery is over seven days behind" if start_at < now - 7 * 86_400
          finish_at = [start_at + MAX_WINDOW, now].min
          return if finish_at <= start_at

          fetch_content_window(type, start_at, finish_at)
          @state.set_checkpoint(key, finish_at.iso8601(3))
          @state.set_checkpoint(replay_key, 'done') if replay_from && replay_key
        end

        def reconcile(type)
          group = "activity:#{type}:reconcile"
          now = @clock.call.utc
          last_started = @state.checkpoint("#{group}:last_started")
          cursor_text = @state.checkpoint("#{group}:cursor")
          target_text = @state.checkpoint("#{group}:target")
          if !cursor_text || cursor_text.empty?
            return if last_started && now - Time.iso8601(last_started) < @config.fetch(:reconciliation_interval)
            @state.set_checkpoint("#{group}:target", now.iso8601(3))
            target_text = now.iso8601(3)
            start_at = now - @config.fetch(:replay_horizon)
            @state.set_checkpoint("#{group}:cursor", start_at.iso8601(3))
            @state.set_checkpoint("#{group}:last_started", now.iso8601(3))
          else
            start_at = Time.iso8601(cursor_text)
          end
          target = Time.iso8601(target_text)
          finish_at = [start_at + MAX_WINDOW, target].min
          return if finish_at <= start_at
          fetch_content_window(type, start_at, finish_at)
          @state.set_checkpoint("#{group}:cursor", finish_at >= target ? '' : finish_at.iso8601(3))
        end

        def fetch_content_window(type, start_at, finish_at)
          url = "#{base_path}/content?contentType=#{URI.encode_www_form_component(type)}&startTime=#{URI.encode_www_form_component(start_at.iso8601)}&endTime=#{URI.encode_www_form_component(finish_at.iso8601)}#{publisher_query}"
          visited = {}
          pages = 0
          while url
            raise 'Microsoft 365 collection stopped' if @stop.call
            raise "Repeated Activity NextPageUri for #{type}" if visited[url]
            raise "Activity pagination limit exceeded for #{type}" if pages >= MAX_PAGES
            visited[url] = true
            response = @http.get('activity', url)
            raise "Invalid Activity discovery response for #{type}" unless response.body.is_a?(Array)
            response.body.each do |blob|
              id = blob.fetch('contentId')
              @state.add_pending("activity:#{type}", id, blob) unless @state.seen?("activity:#{type}:blob", id, 'done')
            end
            drain_pending(type)
            url = response.headers['nextpageuri'] || response.headers['NextPageUri']
            pages += 1
          end
        end

        def drain_pending(type)
          @state.pending("activity:#{type}").each do |id_hash, blob|
            raise 'Microsoft 365 collection stopped' if @stop.call
            content_id = blob.fetch('contentId')
            if blob['contentExpiration'] && Time.iso8601(blob['contentExpiration']) < @clock.call.utc
              raise "Activity blob #{content_id} expired before download; replay source gap"
            end
            records = @http.get('activity', blob.fetch('contentUri')).body
            raise "Invalid Activity blob #{content_id}" unless records.is_a?(Array)
            records.each do |record|
              identity = record['Id'] || record['id'] || Digest::SHA256.hexdigest(JSON.generate(record))
              timestamp = record['CreationTime'] || record['creationTime']
              @emitter.emit(collector: "activity.#{type}", raw: record, identity: identity, timestamp: timestamp)
            end
            @state.mark_seen("activity:#{type}:blob", content_id, 'done')
            @state.remove_pending_hash("activity:#{type}", id_hash)
          end
        end
      end
    end
  end
end
