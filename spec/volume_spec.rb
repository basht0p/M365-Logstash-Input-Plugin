# frozen_string_literal: true

require_relative 'spec_helper'
require 'set'

# High-volume behaviour against the real H2 state. Excluded from the default run; CI runs it with
# M365_VOLUME=1 (rspec --tag volume).
RSpec.describe 'High-volume collection', :volume do
  before { skip 'H2 is only used in JRuby' unless defined?(JRUBY_VERSION) }

  Support = LogStash::Inputs::Microsoft365Support
  RATE = 40 # sign-ins per second: 144,000 per hour, past the old 100,000-row dedupe cap
  PAGE = 1000

  # Serves a deterministic sign-in stream, paged like Graph, for any createdDateTime window.
  class SigninStream
    attr_reader :requests

    def initialize
      @requests = 0
    end

    def get(_resource, url)
      @requests += 1
      params = URI.decode_www_form(URI.parse(url).query).to_h
      if params['$filter']
        first, last = params['$filter'].scan(/\d{4}-\d{2}-\d{2}T[\d:.]+Z/).map { |text| Time.iso8601(text) }
        from = (first.to_r * RATE).ceil
        to = (last.to_r * RATE).floor
        offset = 0
      else
        from, to, offset = params.values_at('from', 'to', 'offset').map(&:to_i)
      end
      ids = (from + offset..[from + offset + PAGE - 1, to].min).to_a
      body = { 'value' => ids.map { |i| { 'id' => "s#{i}", 'createdDateTime' => Time.at(Rational(i, RATE)).utc.iso8601(3) } } }
      body['@odata.nextLink'] = "/next?#{URI.encode_www_form('from' => from, 'to' => to, 'offset' => offset + PAGE)}" if from + offset + PAGE <= to
      Support::Response.new(body: body, headers: {}, status: 200)
    end
  end

  class CountingQueue
    attr_reader :ids

    def initialize
      @ids = Set.new
      @count = 0
    end

    def <<(event)
      @count += 1
      @ids << event.metadata['[@metadata][document_id]']
    end

    def length = @count
  end

  it 'collects an hour past the old caps with dedupe intact across reconciliation and overlap sweeps' do
    Dir.mktmpdir do |path|
      state = Support::State.new(path: path, tenant_id: 'tenant', cloud: 'commercial')
      begin
        now = [Time.utc(2026, 9, 24, 12)]
        config = { overlap: 900, initial_lookback: 3600, poll_interval: 60, reconciliation_interval: 86_400, replay_horizon: 3600 }
        queue = CountingQueue.new
        http = SigninStream.new
        output = Support::Emitter.new(queue: queue, state: state, tenant_id: 'tenant', organization_id: nil, organization_name: nil,
                                      event_factory: ->(data) { FakeEvent.new(data) })
        # 40 pages per window: a 1-hour window needs 144 pages, so it must be split rather than fail.
        collector = Support::GraphCollector.new(name: 'signin', http: http, state: state, emitter: output, config: config,
                                                stop: -> { false }, clock: -> { now.first }, max_pages: 40)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        collector.run_once
        first_pass = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        expected = 3600 * RATE + 1
        expect(queue.length).to eq(expected)
        expect(queue.ids.length).to eq(expected)
        expect(state.checkpoint('signin:default:window')).to eq(now.first.iso8601(3))

        # The trailing sweep on the next poll re-reads ~31 minutes; every record is a duplicate.
        now[0] += 60
        collector.run_once
        expect(queue.length).to eq(expected + 60 * RATE)

        # Nothing inside the dedupe horizon is pruned, however many rows there are.
        expect(state.prune_seen(before: now.first - 10 * 86_400)).to eq(0)
        oldest_id = ((now.first - 60 - 3600).to_r * RATE).ceil
        expect(state.seen?('signin', "s#{oldest_id}", 'immutable')).to be_truthy
        puts format("\n  volume: %<n>d records in %<s>.1fs first pass, %<r>d HTTP requests", n: queue.length, s: first_pass, r: http.requests)
      ensure
        state.close
      end
    end
  end
end
