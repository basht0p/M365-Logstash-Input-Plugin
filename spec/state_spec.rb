# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe LogStash::Inputs::Microsoft365Support::State do
  before { skip 'H2 is only used in JRuby' unless defined?(JRUBY_VERSION) }

  it 'locks a state directory, scopes it to a tenant, and remembers multiple mutable versions' do
    Dir.mktmpdir do |path|
      state = described_class.new(path: path, tenant_id: 'tenant-a', cloud: 'commercial')
      state.set_checkpoint('audit', '2026-09-24T12:00:00Z')
      state.mark_seen('alert', 'id1', 'version1')
      state.mark_seen('alert', 'id1', 'version2')
      expect(state.seen?('alert', 'id1', 'version1')).to be_truthy
      expect(state.seen?('alert', 'id1', 'version2')).to be_truthy
      5.times { |index| state.mark_seen('alert', "extra#{index}", 'v1') }
      expect(state.prune_seen(before: Time.at(0))).to eq(0)
      expect(state.seen?('alert', 'extra0', 'v1')).to be_truthy
      expect { described_class.new(path: path, tenant_id: 'tenant-a', cloud: 'commercial') }.to raise_error(/already owned/)
      state.close
      expect { described_class.new(path: path, tenant_id: 'tenant-b', cloud: 'commercial') }.to raise_error(/belongs to/)
      reopened = described_class.new(path: path, tenant_id: 'tenant-a', cloud: 'commercial')
      expect(reopened.checkpoint('audit')).to eq('2026-09-24T12:00:00Z')
      reopened.close
    end
  end

  it 'prunes by age in batches with no row cap' do
    Dir.mktmpdir do |path|
      state = described_class.new(path: path, tenant_id: 'tenant-a', cloud: 'commercial')
      25.times { |index| state.mark_seen('signin', "id#{index}", 'immutable') }
      expect(state.prune_seen(before: Time.now - 60, batch: 10)).to eq(0)
      expect(state.prune_seen(before: Time.now + 60, batch: 10)).to eq(25)
      expect(state.seen?('signin', 'id0', 'immutable')).to be_falsey
      state.close
    end
  end

  it 'refreshes a touched entry so age-based pruning keeps it' do
    Dir.mktmpdir do |path|
      state = described_class.new(path: path, tenant_id: 'tenant-a', cloud: 'commercial')
      stale = Time.now - 20 * 86_400
      allow(Time).to receive(:now).and_return(stale)
      state.mark_seen('risky_user', 'u1', 'v1')
      state.mark_seen('risky_user', 'u2', 'v1')
      allow(Time).to receive(:now).and_call_original
      expect(state.seen?('risky_user', 'u1', 'v1', touch: true)).to be_truthy
      expect(state.seen?('risky_user', 'u2', 'v1')).to be_truthy
      state.prune_seen(before: Time.now - 10 * 86_400)
      expect(state.seen?('risky_user', 'u1', 'v1')).to be_truthy
      expect(state.seen?('risky_user', 'u2', 'v1')).to be_falsey
      state.close
    end
  end

  it 'writes several checkpoints atomically and deletes nil values' do
    Dir.mktmpdir do |path|
      state = described_class.new(path: path, tenant_id: 'tenant-a', cloud: 'commercial')
      state.set_checkpoints('a' => '1', 'b' => '2')
      state.set_checkpoints('a' => nil, 'b' => '3')
      expect(state.checkpoint('a')).to be_nil
      expect(state.checkpoint('b')).to eq('3')
      expect { state.set_checkpoints('b' => '4', 'x' * 600 => 'too long a key') }.to raise_error(Exception)
      expect(state.checkpoint('b')).to eq('3')
      state.close
    end
  end
end
