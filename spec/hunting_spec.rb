# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe LogStash::Inputs::Microsoft365Support::HuntingCollector do
  let(:now) { Time.utc(2026, 9, 24, 12) }
  let(:state) { FakeState.new }
  let(:queue) { [] }
  let(:config) { { overlap: 0, initial_lookback: 120, hunting_interval: 300 } }

  def with_job(job)
    Dir.mktmpdir do |path|
      file = File.join(path, 'jobs.json')
      File.write(file, JSON.generate('jobs' => [job]))
      yield file
    end
  end

  it 'splits capped incremental windows before emitting and retains checkpoint on success' do
    job = { 'name' => 'devices', 'mode' => 'incremental', 'query' => 'DeviceEvents | where Timestamp between ({{start}} .. {{end}})',
            'timestamp_field' => 'Timestamp', 'identity_fields' => ['ReportId'], 'max_rows' => 2 }
    calls = 0
    http = FakeHTTP.new do |_method, _resource, _url, _body|
      calls += 1
      rows = if calls == 1
               [{ 'ReportId' => 'ignored1', 'Timestamp' => now.iso8601 }, { 'ReportId' => 'ignored2', 'Timestamp' => now.iso8601 }]
             else
               [{ 'ReportId' => calls.to_s, 'Timestamp' => now.iso8601 }]
             end
      response({ 'results' => rows })
    end
    with_job(job) do |path|
      collector = described_class.new(path: path, http: http, state: state, emitter: emitter(state, queue), config: config, stop: -> { false }, clock: -> { now })
      collector.run_once
    end
    expect(calls).to eq(3)
    expect(queue.length).to eq(2)
    expect(state.checkpoints.keys.grep(/:window/).length).to eq(1)
  end

  it 'does not checkpoint capped unsplittable windows' do
    job = { 'name' => 'devices', 'mode' => 'incremental', 'query' => 'DeviceEvents | where Timestamp between ({{start}} .. {{end}})',
            'timestamp_field' => 'Timestamp', 'identity_fields' => ['ReportId'], 'max_rows' => 2 }
    http = FakeHTTP.new { |_method, _resource, _url, _body| response({ 'results' => [{ 'ReportId' => 'a', 'Timestamp' => now.iso8601 }, { 'ReportId' => 'b', 'Timestamp' => now.iso8601 }] }) }
    with_job(job) do |path|
      collector = described_class.new(path: path, http: http, state: state, emitter: emitter(state, queue), config: config, stop: -> { false }, clock: -> { now })
      expect { collector.run_once }.to raise_error(/unsplittable/)
    end
    expect(queue).to be_empty
    expect(state.checkpoints.keys.grep(/:window/)).to be_empty
  end

  let(:incremental_job) do
    { 'name' => 'devices', 'mode' => 'incremental', 'query' => 'DeviceEvents | where Timestamp between ({{start}} .. {{end}})',
      'timestamp_field' => 'Timestamp', 'identity_fields' => ['ReportId'], 'interval' => 300 }
  end

  def run_job(job, clock_time, rows: [])
    http = FakeHTTP.new { |_method, _resource, _url, _body| response({ 'results' => rows }) }
    with_job(job) do |path|
      described_class.new(path: path, http: http, state: state, emitter: emitter(state, queue), config: config, stop: -> { false }, clock: -> { clock_time }).run_once
    end
    http
  end

  it 'keeps progress and document IDs when only scheduling fields change' do
    rows = [{ 'ReportId' => 'r1', 'Timestamp' => now.iso8601 }]
    run_job(incremental_job, now, rows: rows)
    window = state.checkpoints.find { |key, _| key.end_with?(':window') }
    edited = incremental_job.merge('interval' => 900, 'max_rows' => 500, 'initial_lookback' => 7200)
    http = run_job(edited, now + 1000, rows: rows)
    expect(state.checkpoints.keys.grep(/:window\z/)).to eq([window.first])
    expect(http.calls.first[3]['query']).to include("datetime(#{Time.iso8601(window.last).iso8601(3)})")
    expect(queue.length).to eq(1)
  end

  it 'migrates checkpoints stored under the previous whole-job key' do
    legacy = "hunting:devices:#{Digest::SHA256.hexdigest(JSON.generate(incremental_job))}"
    state.set_checkpoint("#{legacy}:window", (now - 60).iso8601(3))
    state.set_checkpoint("#{legacy}:last_run", (now - 600).iso8601(3))
    http = run_job(incremental_job, now)
    expect(http.calls.first[3]['query']).to include("datetime(#{(now - 60).iso8601(3)})")
  end

  it 'does not split snapshot aggregation queries' do
    job = { 'name' => 'summary', 'mode' => 'snapshot', 'query' => 'DeviceEvents | summarize count() by DeviceName', 'max_rows' => 2 }
    http = FakeHTTP.new { |_method, _resource, _url, _body| response({ 'results' => [{ 'DeviceName' => 'a' }, { 'DeviceName' => 'b' }] }) }
    with_job(job) do |path|
      collector = described_class.new(path: path, http: http, state: state, emitter: emitter(state, queue), config: config, stop: -> { false }, clock: -> { now })
      expect { collector.run_once }.to raise_error(/result cap/)
    end
    expect(queue).to be_empty
    expect(http.calls.length).to eq(1)
  end
end
