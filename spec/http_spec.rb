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

  # A stand-in for Net::HTTP that records lifecycle calls and serves a fixed body.
  def fake_transport(body)
    Class.new do
      attr_reader :requests, :finished

      def initialize(body)
        @body = body
        @requests = 0
        @started = false
        @finished = false
      end

      def start = @started = true
      def started? = @started

      def finish
        @started = false
        @finished = true
      end

      def request(_request)
        @requests += 1
        body = @body
        response = Object.new
        response.define_singleton_method(:code) { '200' }
        response.define_singleton_method(:[]) { |_key| nil }
        response.define_singleton_method(:each_header) { {}.each }
        response.define_singleton_method(:read_body) { |&chunk| chunk.call(body) }
        yield response
        response
      end

      %i[use_ssl= verify_mode= open_timeout= read_timeout= keep_alive_timeout=].each { |name| define_method(name) { |_value| } }
    end.new(body)
  end

  it 'enforces a response byte limit while streaming and discards the connection' do
    tiny_client = described_class.new(cloud: cloud, auth: auth, stop: -> { false }, logger: logger, max_body_bytes: 3)
    transports = [fake_transport('too-long'), fake_transport('{}')]
    allow(Net::HTTP).to receive(:new) { transports.first.started? ? transports.last : transports.first }
    expect { tiny_client.get('graph', '/v1.0/auditLogs/signIns') }.to raise_error(LogStash::Inputs::Microsoft365Support::ResponseTooLarge)
    expect(transports.first.finished).to be(true)
  end

  it 'reuses one keep-alive connection per thread and host' do
    transport = fake_transport('{"value":[]}')
    allow(Net::HTTP).to receive(:new).and_return(transport)
    client.get('graph', '/v1.0/auditLogs/signIns')
    client.get('graph', '/v1.0/auditLogs/directoryAudits')
    expect(Net::HTTP).to have_received(:new).once
    expect(transport.requests).to eq(2)
    client.close
    expect(transport.finished).to be(true)
  end

  it 'ignores http_proxy from the environment when no proxy is configured' do
    allow(Net::HTTP).to receive(:new).and_return(fake_transport('{}'))
    client.get('graph', '/v1.0/auditLogs/signIns')
    expect(Net::HTTP).to have_received(:new).with('graph.microsoft.com', 443, nil)
  end

  it 'includes the API error code and message but not the full body' do
    body = JSON.generate('error' => { 'code' => 'Authorization_RequestDenied', 'message' => 'Insufficient privileges' }, 'value' => ['x' * 1000])
    allow(client).to receive(:perform).and_return([fake_response(403), body])
    expect { client.get('graph', '/v1.0/auditLogs/signIns') }.to raise_error(LogStash::Inputs::Microsoft365Support::HTTPError) { |error|
      expect(error.status).to eq(403)
      expect(error.message).to include('Authorization_RequestDenied: Insufficient privileges')
      expect(error.message).not_to include('xxxx')
    }
  end

  it 'retries TLS and connection-refused transport errors' do
    attempts = [OpenSSL::SSL::SSLError.new('reset'), Errno::ECONNREFUSED.new]
    allow(client).to receive(:perform) do
      error = attempts.shift
      raise error if error

      [fake_response(200), '{"value":[]}']
    end
    allow(client).to receive(:interruptible_sleep)
    expect(client.get('graph', '/v1.0/auditLogs/signIns').body).to eq('value' => [])
  end
end
