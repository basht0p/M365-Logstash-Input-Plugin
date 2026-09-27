# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe LogStash::Inputs::Microsoft365Support::TimeWindows do
  let(:start) { Time.utc(2026, 9, 24, 12) }
  let(:state) { FakeState.new }
  let(:config) do
    { overlap: 900, initial_lookback: 3600, poll_interval: 60, reconciliation_interval: 86_400, replay_horizon: 3600 }
  end
  let(:now) { [start] }
  let(:windows) { described_class.new(state: state, config: config, clock: -> { now.first }, max_window: 3600) }

  def advance_collecting
    fetched = []
    gap = windows.advance('c:window') { |s, f, force| fetched << [s, f, force] }
    [fetched, gap]
  end

  it 're-reads the overlap once per overlap period instead of on every poll' do
    advance_collecting
    read_seconds = 0
    30.times do
      now[0] += 60
      fetched, = advance_collecting
      read_seconds += fetched.sum { |s, f, _| f - s }
    end
    # 30 minutes of new data; the old behaviour re-read 15 minutes per poll (~28,800 seconds).
    expect(read_seconds).to be < 5 * 1800
    expect(state.checkpoint('c:window')).to eq(now.first.iso8601(3))
  end

  it 'still collects records that arrive up to overlap seconds late' do
    # Records carry timestamp t but only become visible to the API at t + delay.
    records = (0...240).map { |i| { at: start + i * 17, delay: (i * 131) % config[:overlap] } }
    collected = {}
    advance_collecting
    120.times do
      now[0] += 60
      windows.advance('c:window') do |s, f, _force|
        records.each do |r|
          collected[r] = true if r[:at] >= s && r[:at] <= f && r[:at] + r[:delay] <= now.first
        end
      end
    end
    eligible = records.select { |r| r[:at] + r[:delay] <= now.first - config[:overlap] }
    expect(eligible.length).to be > 200
    expect(eligible.reject { |r| collected[r] }).to be_empty
  end

  it 'forces the replay range up to the cursor position at replay start, then stops forcing' do
    advance_collecting
    now[0] += 7200
    advance_collecting
    position = Time.iso8601(state.checkpoint('c:window'))
    config[:replay_from] = (start - 1800).iso8601
    forced = []
    8.times do
      now[0] += 60
      windows.advance('c:window') { |s, f, force| forced << [s, f] if force }
    end
    expect(forced.first.first).to eq(start - 1800)
    expect(forced.last.last).to be >= position
    expect(forced.map(&:first).max).to be < position
    expect(state.checkpoint("c:window:replay:#{config[:replay_from]}")).to eq('done')
  end

  it 'skips past windows the source no longer serves and reports the gap once' do
    aged = described_class.new(state: state, config: config, clock: -> { now.first }, max_window: 86_400, max_age: 7 * 86_400)
    state.set_checkpoint('c:window', (start - 9 * 86_400).iso8601(3))
    fetched = []
    gap = aged.advance('c:window') { |s, f, _| fetched << [s, f] }
    expect(gap).to include((start - 9 * 86_400).iso8601(3))
    expect(fetched.map(&:first).min).to be >= start - 7 * 86_400
    now[0] += 60
    expect(aged.advance('c:window') { |*| nil }).to be_nil
  end

  it 'clamps an aged reconciliation cursor instead of failing on it forever' do
    aged = described_class.new(state: state, config: config, clock: -> { now.first }, max_window: 86_400, max_age: 7 * 86_400)
    state.set_checkpoints('c:reconcile:cursor' => (start - 8 * 86_400).iso8601(3), 'c:reconcile:target' => start.iso8601(3))
    fetched = []
    aged.reconcile('c:reconcile') { |s, f| fetched << [s, f] }
    expect(fetched.first.first).to eq(start - 7 * 86_400)
  end

  it 'splits a window that exceeds the page budget and fails only below the minimum size' do
    calls = []
    windows.advance('c:window') do |s, f, _|
      calls << (f - s)
      raise LogStash::Inputs::Microsoft365Support::WindowTooLarge, 'too many pages' if f - s > 900
    end
    expect(calls.first).to eq(3600)
    expect(calls.count { |span| span <= 900 }).to eq(4)
    expect(state.checkpoint('c:window')).to eq(start.iso8601(3))

    now[0] += 60
    expect do
      windows.advance('c:window') { |*| raise LogStash::Inputs::Microsoft365Support::WindowTooLarge, 'too many pages' }
    end.to raise_error(LogStash::Inputs::Microsoft365Support::WindowTooLarge, /cannot be split further/)
  end
end
