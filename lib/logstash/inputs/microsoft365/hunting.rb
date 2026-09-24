# frozen_string_literal: true

require 'json'
require 'time'
require 'digest'

module LogStash
  module Inputs
    module Microsoft365Support
      class HuntingCollector
        MAX_WINDOW = 3600
        MIN_SPLIT_SECONDS = 60

        def initialize(path:, http:, state:, emitter:, config:, stop:, clock: -> { Time.now.utc })
          @http, @state, @emitter, @config, @stop, @clock = http, state, emitter, config, stop, clock
          definition = JSON.parse(::File.read(path))
          jobs = definition.is_a?(Array) ? definition : definition.fetch('jobs')
          raise 'Hunting jobs must be a nonempty array' unless jobs.is_a?(Array) && !jobs.empty?
          names = {}
          @jobs = jobs.map do |job|
            validate_job(job)
            raise "Duplicate hunting job #{job['name']}" if names[job['name']]
            names[job['name']] = true
            job
          end
        end

        def run_once
          @jobs.each do |job|
            raise 'Microsoft 365 collection stopped' if @stop.call
            key = checkpoint_key(job)
            last_run = @state.checkpoint("#{key}:last_run")
            now = @clock.call.utc
            next if last_run && now - Time.iso8601(last_run) < job.fetch('interval', @config.fetch(:hunting_interval)).to_i

            if job.fetch('mode') == 'snapshot'
              snapshot(job, now)
            else
              incremental(job, now)
            end
            @state.set_checkpoint("#{key}:last_run", now.iso8601(3))
          end
        end

        private

        def validate_job(job)
          raise 'Hunting job must be an object' unless job.is_a?(Hash)
          name = job['name']
          raise 'Hunting job name must use letters, digits, underscore, or dash' unless name.is_a?(String) && name.match?(/\A[a-zA-Z0-9_-]+\z/)
          query = job['query']
          raise "Hunting query #{name} is empty" unless query.is_a?(String) && !query.strip.empty?
          mode = job['mode']
          raise "Hunting mode invalid for #{name}" unless %w[incremental snapshot].include?(mode)
          raise "Hunting interval invalid for #{name}" if job.key?('interval') && job['interval'].to_i < 60
          max_rows = job.fetch('max_rows', 100_000).to_i
          raise "Hunting max_rows invalid for #{name}" unless max_rows.between?(2, 100_000)
          if mode == 'incremental'
            raise "Hunting query #{name} must contain {{start}} and {{end}}" unless query.include?('{{start}}') && query.include?('{{end}}')
            raise "Hunting query #{name} needs a timestamp_field" unless job['timestamp_field'].is_a?(String) && !job['timestamp_field'].empty?
            raise "Hunting query #{name} needs identity_fields" unless job['identity_fields'].is_a?(Array) && !job['identity_fields'].empty? && job['identity_fields'].all? { |field| field.is_a?(String) && !field.empty? }
            raise "Hunting query #{name} uses an aggregation or row cap; use snapshot mode" if query.match?(/\|\s*(summarize|count|distinct|top|take|limit|sample|make-series)\b/i)
          end
        end

        def checkpoint_key(job)
          "hunting:#{job.fetch('name')}:#{Digest::SHA256.hexdigest(JSON.generate(job))}"
        end

        def snapshot(job, now)
          pending_key = "#{checkpoint_key(job)}:pending_run"
          run_id = @state.checkpoint(pending_key)
          if !run_id || run_id.empty?
            run_id = now.iso8601(3)
            @state.set_checkpoint(pending_key, run_id)
          end
          rows = query(job.fetch('query'))
          check_cap(job, rows)
          rows.each_with_index do |row, index|
            identity = "#{run_id}:#{row_identity(job, row, index)}"
            @emitter.emit(collector: "hunting.#{job['name']}", raw: row, identity: identity, timestamp: row[job.fetch('timestamp_field', 'Timestamp')] || run_id, revision: run_id)
          end
          @state.set_checkpoint(pending_key, '')
        end

        def incremental(job, now)
          key = "#{checkpoint_key(job)}:window"
          previous = @state.checkpoint(key)
          lookback = job.fetch('initial_lookback', @config.fetch(:initial_lookback)).to_i
          start_at = previous ? Time.iso8601(previous) - @config.fetch(:overlap) : now - lookback
          finish_at = [start_at + MAX_WINDOW, now].min
          return if finish_at <= start_at

          collect_window(job, start_at, finish_at)
          @state.set_checkpoint(key, finish_at.iso8601(3))
        end

        def collect_window(job, start_at, finish_at)
          text = job.fetch('query').gsub('{{start}}', "datetime(#{start_at.iso8601(3)})").gsub('{{end}}', "datetime(#{finish_at.iso8601(3)})")
          begin
            rows = query(text)
          rescue ResponseTooLarge
            split_window(job, start_at, finish_at)
            return
          end
          limit = job.fetch('max_rows', 100_000).to_i
          if rows.length >= limit
            split_window(job, start_at, finish_at)
            return
          end
          rows.each_with_index do |row, index|
            identity = row_identity(job, row, index)
            timestamp = row[job.fetch('timestamp_field')]
            raise "Hunting job #{job['name']} returned row without timestamp" unless timestamp
            @emitter.emit(collector: "hunting.#{job['name']}", raw: row, identity: identity, timestamp: timestamp, revision: Digest::SHA256.hexdigest(JSON.generate(job)))
          end
        end

        def split_window(job, start_at, finish_at)
          midpoint = Time.at((start_at.to_f + finish_at.to_f) / 2).utc
          raise "Hunting job #{job['name']} reached result cap in an unsplittable window" if finish_at - start_at <= MIN_SPLIT_SECONDS
          collect_window(job, start_at, midpoint)
          collect_window(job, midpoint, finish_at)
        end

        def query(text)
          raise 'Microsoft 365 collection stopped' if @stop.call
          response = @http.post('graph', '/v1.0/security/runHuntingQuery', { 'query' => text })
          data = response.body
          raise 'Invalid Graph hunting response' unless data.is_a?(Hash) && data['results'].is_a?(Array)
          data['results']
        end

        def check_cap(job, rows)
          raise "Hunting snapshot #{job['name']} reached result cap" if rows.length >= job.fetch('max_rows', 100_000).to_i
        end

        def row_identity(job, row, index)
          fields = job['identity_fields']
          if fields.is_a?(Array) && !fields.empty?
            values = fields.map { |field| row[field] }
            raise "Hunting job #{job['name']} missing identity field" if values.any?(&:nil?)
            Digest::SHA256.hexdigest(JSON.generate(values))
          else
            Digest::SHA256.hexdigest(JSON.generate([index, row]))
          end
        end
      end
    end
  end
end
