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

  def window_seconds(url)
    filter = URI.decode_www_form(URI.parse(url).query).to_h.fetch('$filter')
    times = filter.scan(/\d{4}-\d{2}-\d{2}T[\d:.]+Z/).map { |text| Time.iso8601(text) }
    times.last - times.first
  end

  it 'splits Graph windows that exceed the page budget instead of failing forever' do
    http = FakeHTTP.new do |_method, _resource, url, _body|
      if url.start_with?('/page')
        response({ 'value' => [{ 'id' => url, 'createdDateTime' => now.iso8601 }], '@odata.nextLink' => "/page#{url.length}x" })
      elsif window_seconds(url) > 900
        response({ 'value' => [{ 'id' => 'first', 'createdDateTime' => now.iso8601 }], '@odata.nextLink' => '/page' })
      else
        response({ 'value' => [{ 'id' => url, 'createdDateTime' => now.iso8601 }] })
      end
    end
    collector = LogStash::Inputs::Microsoft365Support::GraphCollector.new(name: 'signin', http: http, state: state, emitter: output, config: config, stop: -> { false }, clock: -> { now }, max_pages: 3)
    collector.run_once
    expect(state.checkpoint('signin:default:window')).to eq(now.iso8601(3))
    first_url = http.calls.first[2]
    expect(URI.decode_www_form(URI.parse(first_url).query).to_h['$top']).to eq('1000')
    expect(http.calls.map { |call| call[2] }.reject { |url| url.start_with?('/page') }.map { |url| window_seconds(url) }.min).to be <= 900
  end

  it 'refreshes dedupe entries for unchanged risk records on every full listing' do
    http = FakeHTTP.new { |_method, _resource, _url, _body| response({ 'value' => [{ 'id' => 'risk1', 'detectedDateTime' => now.iso8601, 'riskState' => 'atRisk' }] }) }
    collector = LogStash::Inputs::Microsoft365Support::GraphCollector.new(name: 'risk_detection', http: http, state: state, emitter: output, config: config, stop: -> { false }, clock: -> { now })
    3.times { collector.run_once }
    expect(queue.length).to eq(1)
    expect(state.touches[%w[risk_detection risk1]]).to eq(2)
    expect(http.calls.first[2]).to include('%24top=500')
  end

  it 'replay_from re-delivers Graph records that were already delivered' do
    http = FakeHTTP.new { |_method, _resource, _url, _body| response({ 'value' => [{ 'id' => 'a', 'createdDateTime' => (now - 600).iso8601 }] }) }
    collector = LogStash::Inputs::Microsoft365Support::GraphCollector.new(name: 'signin', http: http, state: state, emitter: output, config: config, stop: -> { false }, clock: -> { now })
    collector.run_once
    expect(queue.length).to eq(1)
    replay = LogStash::Inputs::Microsoft365Support::GraphCollector.new(name: 'signin', http: http, state: state, emitter: output, config: config.merge(replay_from: (now - 1800).iso8601), stop: -> { false }, clock: -> { now + 60 })
    replay.run_once
    expect(queue.length).to eq(2)
    expect(queue.map { |event| event.metadata['[@metadata][document_id]'] }.uniq.length).to eq(1)
  end

  def activity_http(types, content: ->(_type, _url) { [] }, blobs: {})
    FakeHTTP.new do |_method, _resource, url, _body|
      case url
      when %r{/list} then response(types.map { |type| { 'contentType' => type, 'status' => 'enabled' } })
      when /\/content\?contentType=([^&]+)/ then response(content.call(URI.decode_www_form_component(Regexp.last_match(1)), url))
      else blobs.key?(url) ? response(blobs.fetch(url)) : raise("unexpected #{url}")
      end
    end
  end

  it 'skips an expired Activity blob once, reports the gap, and keeps collecting' do
    expired = { 'contentId' => 'old', 'contentUri' => 'https://manage.office.com/old', 'contentExpiration' => (now - 60).iso8601 }
    state.add_pending('activity:Audit.Exchange', 'old', expired)
    http = activity_http(['Audit.Exchange'])
    collector = LogStash::Inputs::Microsoft365Support::ActivityCollector.new(http: http, state: state, emitter: output, config: config, stop: -> { false }, clock: -> { now })
    expect { collector.run_once }.to raise_error(LogStash::Inputs::Microsoft365Support::SourceGap, /blob old expired/)
    expect(state.pending('activity:Audit.Exchange')).to be_empty
    expect(state.checkpoint('activity:Audit.Exchange:window')).to eq(now.iso8601(3))
    expect { collector.run_once }.not_to raise_error
    expect(http.calls.map { |call| call[2] }).not_to include(expired['contentUri'])
  end

  it 'skips Activity discovery that fell more than seven days behind' do
    state.set_checkpoint('activity:Audit.Exchange:window', (now - 10 * 86_400).iso8601(3))
    starts = []
    http = activity_http(['Audit.Exchange'], content: lambda { |_type, url|
      starts << Time.iso8601(URI.decode_www_form(URI.parse(url).query).to_h.fetch('startTime'))
      []
    })
    collector = LogStash::Inputs::Microsoft365Support::ActivityCollector.new(http: http, state: state, emitter: output, config: config, stop: -> { false }, clock: -> { now })
    expect { collector.run_once }.to raise_error(LogStash::Inputs::Microsoft365Support::SourceGap, /discovery skipped/)
    expect(starts.min).to be >= now - 7 * 86_400
    expect(Time.iso8601(state.checkpoint('activity:Audit.Exchange:window'))).to be > now - 7 * 86_400
  end

  it 'collects each Activity content type independently and backs off only the failing one' do
    blob = { 'contentId' => 'sp1', 'contentUri' => 'https://manage.office.com/sp1' }
    http = activity_http(%w[Audit.Exchange Audit.SharePoint],
                         content: lambda { |type, url|
                           raise LogStash::Inputs::Microsoft365Support::HTTPError.new(403, url, 'AF10001: denied') if type == 'Audit.Exchange'

                           [blob]
                         },
                         blobs: { blob['contentUri'] => [{ 'Id' => 'sp-event', 'CreationTime' => '2026-09-24T11:59:00' }] })
    clock = [now]
    collector = LogStash::Inputs::Microsoft365Support::ActivityCollector.new(http: http, state: state, emitter: output,
                                                                             config: config.merge(activity_content_types: %w[Audit.Exchange Audit.SharePoint]),
                                                                             stop: -> { false }, clock: -> { clock.first })
    expect { collector.run_once }.to raise_error(LogStash::Inputs::Microsoft365Support::PartialFailure, /Audit.Exchange: .*403.*AF10001/)
    expect(queue.map { |event| event.data.dig('event', 'id') }).to eq(['sp-event'])
    expect(queue.first.data['@timestamp']).to eq('2026-09-24T11:59:00Z')
    exchange_calls = -> { http.calls.count { |call| call[2].include?('contentType=Audit.Exchange') } }
    before = exchange_calls.call
    clock[0] += 60
    expect { collector.run_once }.not_to raise_error
    expect(exchange_calls.call).to eq(before)
    clock[0] += 3600
    expect { collector.run_once }.to raise_error(LogStash::Inputs::Microsoft365Support::PartialFailure)
    expect(exchange_calls.call).to be > before
  end

  it 'replay_from re-downloads Activity blobs that were already completed' do
    blob = { 'contentId' => 'blob1', 'contentUri' => 'https://manage.office.com/blob1' }
    http = activity_http(['Audit.Exchange'], content: ->(_type, _url) { [blob] },
                                             blobs: { blob['contentUri'] => [{ 'Id' => 'event1', 'CreationTime' => (now - 600).iso8601 }] })
    collector = LogStash::Inputs::Microsoft365Support::ActivityCollector.new(http: http, state: state, emitter: output, config: config, stop: -> { false }, clock: -> { now })
    collector.run_once
    replay = LogStash::Inputs::Microsoft365Support::ActivityCollector.new(http: http, state: state, emitter: output, config: config.merge(replay_from: (now - 1800).iso8601), stop: -> { false }, clock: -> { now + 60 })
    replay.run_once
    expect(queue.length).to eq(2)
    expect(state.pending('activity:Audit.Exchange')).to be_empty
  end
end
