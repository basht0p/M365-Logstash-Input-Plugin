# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe 'Microsoft 365 collectors' do
  let(:now) { Time.utc(2026, 9, 24, 12) }
  let(:state) { FakeState.new }
  let(:queue) { [] }
  let(:output) { emitter(state, queue) }
  let(:config) do
    { overlap: 900, initial_lookback: 3600, signin_types: %w[servicePrincipal managedIdentity],
      activity_content_types: ['Audit.Exchange'], tenant_id: 'tenant', publisher_identifier: nil, hunting_interval: 300,
      reconciliation_interval: 86_400, replay_horizon: 3600 }
  end

  it 'follows Graph pages and checkpoints only after all pages enqueue' do
    http = FakeHTTP.new do |_method, _resource, url, _body|
      if url == '/next'
        response({ 'value' => [{ 'id' => 'b', 'createdDateTime' => now.iso8601 }] })
      else
        response({ 'value' => [{ 'id' => 'a', 'createdDateTime' => now.iso8601 }], '@odata.nextLink' => '/next' })
      end
    end
    collector = LogStash::Inputs::Microsoft365Support::GraphCollector.new(name: 'signin', http: http, state: state, emitter: output, config: config, stop: -> { false }, clock: -> { now })
    collector.run_once
    expect(queue.map { |event| event.data.dig('event', 'id') }).to eq(%w[a b])
    expect(state.checkpoint('signin:default:window')).to eq(now.iso8601(3))
  end

  it 'does not checkpoint after a queue failure and safely replays' do
    http = FakeHTTP.new { |_method, _resource, _url, _body| response({ 'value' => [{ 'id' => 'a', 'createdDateTime' => now.iso8601 }] }) }
    failing_queue = Object.new
    def failing_queue.<<(_event) = raise('queue full')
    collector = LogStash::Inputs::Microsoft365Support::GraphCollector.new(name: 'signin', http: http, state: state, emitter: emitter(state, failing_queue), config: config, stop: -> { false }, clock: -> { now })
    expect { collector.run_once }.to raise_error('queue full')
    expect(state.checkpoint('signin:default:window')).to be_nil
    collector = LogStash::Inputs::Microsoft365Support::GraphCollector.new(name: 'signin', http: http, state: state, emitter: output, config: config, stop: -> { false }, clock: -> { now })
    collector.run_once
    expect(queue.length).to eq(1)
  end

  it 'keeps separate beta sign-in category progress' do
    http = FakeHTTP.new { |_method, _resource, _url, _body| response({ 'value' => [] }) }
    collector = LogStash::Inputs::Microsoft365Support::GraphCollector.new(name: 'signin_beta', http: http, state: state, emitter: output, config: config, stop: -> { false }, clock: -> { now })
    collector.run_once
    expect(state.checkpoint('signin_beta:servicePrincipal:window')).to eq(now.iso8601(3))
    expect(state.checkpoint('signin_beta:managedIdentity:window')).to eq(now.iso8601(3))
    expect(http.calls.map { |call| call[2] }.join).to include('servicePrincipal', 'managedIdentity')
  end

  it 'emits changed Defender versions once each across overlapping queries' do
    version = 1
    http = FakeHTTP.new { |_method, _resource, _url, _body| response({ 'value' => [{ 'id' => 'alert', 'lastUpdateDateTime' => now.iso8601, 'severity' => version }] }) }
    collector = LogStash::Inputs::Microsoft365Support::GraphCollector.new(name: 'defender_alert', http: http, state: state, emitter: output, config: config, stop: -> { false }, clock: -> { now })
    collector.run_once
    version = 2
    collector.run_once
    version = 1
    collector.run_once
    expect(queue.length).to eq(2)
    expect(queue.map { |event| event.metadata['[@metadata][document_id]'] }.uniq.length).to eq(2)
    expect(queue.map { |event| event.metadata['[@metadata][entity_id]'] }.uniq.length).to eq(1)
  end

  it 'preserves an existing disabled Activity subscription' do
    http = FakeHTTP.new { |_method, _resource, _url, _body| response([{ 'contentType' => 'Audit.Exchange', 'status' => 'disabled' }]) }
    collector = LogStash::Inputs::Microsoft365Support::ActivityCollector.new(http: http, state: state, emitter: output, config: config, stop: -> { false }, clock: -> { now })
    expect { collector.run_once }.to raise_error(/disabled/)
    expect(http.calls.map(&:first)).to eq([:get])
  end

  it 'persists Activity blobs until every record is enqueued and skips repeated blobs' do
    blob = { 'contentId' => 'blob1', 'contentUri' => 'https://manage.office.com/blob1' }
    http = FakeHTTP.new do |_method, _resource, url, _body|
      case url
      when /\/list/ then response([{ 'contentType' => 'Audit.Exchange', 'status' => 'enabled' }])
      when /\/content\?/ then response([blob])
      when blob['contentUri'] then response([{ 'Id' => 'event1', 'CreationTime' => now.iso8601 }])
      else raise url
      end
    end
    collector = LogStash::Inputs::Microsoft365Support::ActivityCollector.new(http: http, state: state, emitter: output, config: config, stop: -> { false }, clock: -> { now })
    collector.run_once
    collector.run_once
    expect(queue.length).to eq(1)
    expect(http.calls.count { |call| call[2] == blob['contentUri'] }).to eq(1)
    expect(state.pending('activity:Audit.Exchange')).to be_empty
  end
end
