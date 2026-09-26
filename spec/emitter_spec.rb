# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe LogStash::Inputs::Microsoft365Support::Emitter do
  let(:state) { FakeState.new }
  let(:queue) { [] }

  it 'decorates before enqueue and suppresses unchanged replay' do
    decorate = ->(event) { event.data['tags'] = ['added-by-logstash'] }
    output = described_class.new(queue: queue, state: state, tenant_id: 'tenant', organization_id: nil, organization_name: nil,
                                 decorate: decorate, event_factory: ->(data) { FakeEvent.new(data) })
    raw = { 'id' => 'one', 'ipAddress' => '198.51.100.2:443', 'deviceDetail' => { 'deviceId' => 'dev', 'extra' => 'raw-only' } }
    expect(output.emit(collector: 'signin', raw: raw, identity: 'one')).to be_truthy
    expect(output.emit(collector: 'signin', raw: raw, identity: 'one')).to be_falsey
    expect(queue.length).to eq(1)
    expect(queue.first.data['tags']).to eq(['added-by-logstash'])
    expect(queue.first.data.dig('source', 'ip')).to eq('198.51.100.2')
    expect(queue.first.data['device']).to eq('id' => 'dev')
  end

  it 're-emits a delivered record when forced, keeping its deterministic IDs' do
    output = described_class.new(queue: queue, state: state, tenant_id: 'tenant', organization_id: nil, organization_name: nil,
                                 event_factory: ->(data) { FakeEvent.new(data) })
    raw = { 'id' => 'one' }
    expect(output.emit(collector: 'signin', raw: raw, identity: 'one')).to be_truthy
    expect(output.emit(collector: 'signin', raw: raw, identity: 'one', force: true)).to be_truthy
    expect(queue.map { |event| event.metadata['[@metadata][document_id]'] }.uniq.length).to eq(1)
  end

  it 'treats timestamps without a zone designator as UTC' do
    results = []
    output = described_class.new(queue: queue, state: state, tenant_id: 'tenant', organization_id: nil, organization_name: nil,
                                 on_result: ->(_collector, _emitted, timestamp) { results << timestamp },
                                 event_factory: ->(data) { FakeEvent.new(data) })
    output.emit(collector: 'activity.Audit.Exchange', raw: { 'Id' => 'a' }, identity: 'a', timestamp: '2026-09-24T12:00:00')
    output.emit(collector: 'signin', raw: { 'id' => 'b' }, identity: 'b', timestamp: '2026-09-24T12:00:00.1234567+02:00')
    expect(queue.map { |event| event.data['@timestamp'] }).to eq(['2026-09-24T12:00:00Z', '2026-09-24T12:00:00.1234567+02:00'])
    expect(results.first).to eq('2026-09-24T12:00:00Z')
  end

  it 'omits ECS fields when compatibility is disabled while retaining source and metadata' do
    output = described_class.new(queue: queue, state: state, tenant_id: 'tenant', organization_id: 'org', organization_name: 'Org',
                                 ecs_compatibility: 'disabled', event_factory: ->(data) { FakeEvent.new(data) })
    output.emit(collector: 'signin', raw: { 'id' => 'one', 'userPrincipalName' => 'user@example.test' }, identity: 'one')
    event = queue.first
    expect(event.data).not_to have_key('event')
    expect(event.data).not_to have_key('user')
    expect(event.data.dig('microsoft', 'source_id')).to eq('one')
    expect(event.metadata['[@metadata][entity_id]']).to match(/\A[0-9a-f]{64}\z/)
  end
end
