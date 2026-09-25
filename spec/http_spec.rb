# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe LogStash::Inputs::Microsoft365Support::HTTP do
  let(:cloud) { LogStash::Inputs::Microsoft365Support::Manifest.cloud('commercial') }
  let(:auth) do
    Object.new.tap do |object|
      def object.token(_resource) = 'token'
      def object.invalidate = (@invalidated = true)
      def object.invalidated? = @invalidated
    end
  end
  let(:logger) { Object.new.tap { |object| def object.warn(*_args); end } }
  let(:client) { described_class.new(cloud: cloud, auth: auth, stop: -> { false }, logger: logger) }

  def fake_response(status, retry_after = nil)
    Struct.new(:code, :retry_after) do
      def [](key) = key == 'Retry-After' ? retry_after : nil
      def each_header = {}.each
    end.new(status.to_s, retry_after)
  end

  it 'rejects foreign cloud continuation and blob hosts before adding a token' do
    expect { client.get('graph', 'https://graph.microsoft.us/v1.0/auditLogs/signIns') }.to raise_error(/Cross-cloud/)
    expect { client.get('activity', 'https://manage-gcc.office.com/api/v1.0/tenant') }.to raise_error(/Cross-cloud/)
  end

  it 'honors Retry-After values longer than the exponential cap' do
    responses = [[fake_response(429, '240'), ''], [fake_response(200), '{"value":[]}']]
    allow(client).to receive(:perform) { responses.shift }
    waits = []
    allow(client).to receive(:interruptible_sleep) { |seconds| waits << seconds }
    expect(client.get('graph', '/v1.0/auditLogs/signIns').body).to eq('value' => [])
    expect(waits).to eq([240])
  end

  it 'refreshes credentials once on 401' do
    responses = [[fake_response(401), ''], [fake_response(200), '{"value":[]}']]
    allow(client).to receive(:perform) { responses.shift }
    client.get('graph', '/v1.0/auditLogs/signIns')
    expect(auth.invalidated?).to be_truthy
  end

  it 'enforces a response byte limit while streaming' do
    tiny_client = described_class.new(cloud: cloud, auth: auth, stop: -> { false }, logger: logger, max_body_bytes: 3)
    response = Object.new
    def response.read_body
      yield 'too-long'
    end
    transport = Object.new
    transport.define_singleton_method(:request) { |_request, &block| block.call(response) }
    %i[use_ssl= verify_mode= open_timeout= read_timeout=].each { |name| transport.define_singleton_method(name) { |_value| } }
    allow(Net::HTTP).to receive(:new).and_return(transport)
    expect { tiny_client.get('graph', '/v1.0/auditLogs/signIns') }.to raise_error(LogStash::Inputs::Microsoft365Support::ResponseTooLarge)
  end
end
