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
      expect { state.prune_seen(before: Time.at(0), limit: 3) }.not_to raise_error
      expect { described_class.new(path: path, tenant_id: 'tenant-a', cloud: 'commercial') }.to raise_error(/already owned/)
      state.close
      expect { described_class.new(path: path, tenant_id: 'tenant-b', cloud: 'commercial') }.to raise_error(/belongs to/)
      reopened = described_class.new(path: path, tenant_id: 'tenant-a', cloud: 'commercial')
      expect(reopened.checkpoint('audit')).to eq('2026-09-24T12:00:00Z')
      reopened.close
    end
  end
end
