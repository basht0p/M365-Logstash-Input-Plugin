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
