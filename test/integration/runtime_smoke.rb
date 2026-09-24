# frozen_string_literal: true

# Run with test/integration/run_in_logstash.sh inside a real Logstash image.
# This loads Logstash's bundled JRuby, Base input, Event and Java runtime.
require 'tmpdir'
require 'fileutils'
require 'timeout'
require 'openssl'

home = ENV.fetch('LOGSTASH_HOME', '/usr/share/logstash')
require File.join(home, 'lib', 'bootstrap', 'environment')
LogStash::Bundler.setup!(without: %i[build development])
require File.join(home, 'logstash-core', 'lib', 'jars', 'logstash-core.jar')
$LOAD_PATH.unshift(File.join(home, 'logstash-core', 'lib'))
$LOAD_PATH.unshift(File.join(home, 'logstash-core-plugin-api', 'lib'))
$LOAD_PATH.unshift(File.join(Dir.pwd, 'lib'))
require 'logstash/environment'
require 'logstash/event'
require 'logstash/codecs/plain'
require 'logstash/codecs/json'
require 'logstash/inputs/microsoft365'

TENANT = '11111111-1111-1111-1111-111111111111'
CLIENT = '22222222-2222-2222-2222-222222222222'
Support = LogStash::Inputs::Microsoft365Support

def assert(condition, message)
  raise "INTEGRATION FAILURE: #{message}" unless condition
end

def wait_until(seconds: 8)
  Timeout.timeout(seconds) do
    until yield
      sleep 0.05
    end
  end
end

class LocalHTTP
  attr_accessor :on_retry
  attr_reader :calls

  def initialize(record)
    @record = record
    @calls = Queue.new
  end

  def get(resource, url)
    raise "unexpected resource #{resource}" unless resource == 'graph'
    @calls << url
    Support::Response.new(body: { 'value' => [@record] }, headers: {}, status: 200)
  end

  def post(*)
    raise 'unexpected HTTP POST'
  end
end

def test_certificate(path)
  key = OpenSSL::PKey::RSA.new(3072)
  cert = OpenSSL::X509::Certificate.new
  cert.version = 2
  cert.serial = 1
  cert.subject = cert.issuer = OpenSSL::X509::Name.parse('/CN=Logstash integration test')
  cert.public_key = key.public_key
  cert.not_before = Time.now - 60
  cert.not_after = Time.now + 3600
  cert.sign(key, OpenSSL::Digest::SHA256.new)
  File.binwrite(path, OpenSSL::PKCS12.create('test-pfx-password', 'integration-test', key, cert).to_der)
end

Dir.mktmpdir('m365-logstash-runtime-') do |root|
  state_path = File.join(root, 'state')
  record = {
    'id' => 'integration-signin-1',
    'createdDateTime' => '2026-01-01T00:00:00Z',
    'userPrincipalName' => 'reader@example.test',
    'ipAddress' => '198.51.100.4',
    'status' => { 'errorCode' => 0 }
  }
  config = {
    'tenant_id' => TENANT, 'client_id' => CLIENT, 'cloud' => 'commercial',
    'collectors' => ['signin'], 'client_secret' => 'local-test-secret',
    'state_path' => state_path, 'poll_interval' => 300,
    'initial_lookback' => 3600, 'replay_horizon' => 3600,
    'tags' => ['integration-tag'],
    'organization_id' => 'integration-org', 'organization_name' => 'Integration Org'
  }
  input = LogStash::Inputs::Microsoft365.new(config)
  input.register
  state = input.instance_variable_get(:@state)
  assert(state.is_a?(Support::State), 'register must create the real H2 State')
  assert(input.instance_variable_get(:@auth).is_a?(Support::Auth), 'register must build real MSAL4J Auth')

  # A second owner cannot register against this directory while the first is running.
  begin
    Support::State.new(path: state_path, tenant_id: TENANT, cloud: 'commercial')
    raise 'second state owner unexpectedly succeeded'
  rescue => error
    assert(error.message.include?('already owned'), "concurrent state lock: #{error.message}")
  end

  http = LocalHTTP.new(record)
  input.instance_variable_set(:@http, http)
  queue = SizedQueue.new(1)
  queue << :blocker
  run_thread = Thread.new { input.run(queue) }
  begin
    wait_until { !http.calls.empty? }
    assert(queue.length == 1, 'backpressure should block the event')
    assert(!state.seen?('signin', record.fetch('id'), 'immutable'), 'record must remain uncommitted before queue acceptance')
    assert(state.checkpoint('signin:default:window').nil?, 'checkpoint must not advance before queue acceptance')
    assert(queue.pop == :blocker, 'initial queue blocker missing')
    wait_until { !queue.empty? }
    event = queue.pop
    assert(event.is_a?(LogStash::Event), 'emitted object must be a real LogStash::Event')
    assert(event.get('[event][dataset]') == 'microsoft365.signin', 'dataset mapping')
    assert(event.get('[event][outcome]') == 'success', 'outcome mapping')
    assert(event.get('[user][name]') == 'reader@example.test', 'user mapping')
    assert(event.get('[source][ip]') == '198.51.100.4', 'IP mapping')
    assert(event.get('[@metadata][document_id]')&.length == 64, 'stable document ID metadata')
    assert(event.get('[@metadata][entity_id]')&.length == 64, 'stable entity ID metadata')
    assert(event.get('[microsoft][raw][id]') == record.fetch('id'), 'raw source data')
    assert(event.get('tags').include?('integration-tag'), 'Logstash input decoration must preserve configured tags')
    wait_until { state.seen?('signin', record.fetch('id'), 'immutable') }
    wait_until { state.checkpoint('signin:default:window') && state.checkpoint('signin:default:reconcile:cursor') == '' }
    input.stop
    run_thread.join(8)
    assert(!run_thread.alive?, 'run must exit after stop')
    run_thread.value
  ensure
    input.stop
    run_thread.join(8)
    input.close
  end

  reopened = Support::State.new(path: state_path, tenant_id: TENANT, cloud: 'commercial')
  begin
    assert(reopened.seen?('signin', record.fetch('id'), 'immutable'), 'seen marker must survive H2 reopen')
    assert(!reopened.checkpoint('signin:default:window').nil?, 'window checkpoint must survive H2 reopen')
    mutable_queue = Queue.new
    emitter = Support::Emitter.new(
      queue: mutable_queue, state: reopened, tenant_id: TENANT,
      organization_id: nil, organization_name: nil,
      event_factory: ->(data) { LogStash::Event.new(data) }
    )
    first = { 'id' => 'alert-1', 'status' => 'new' }
    changed = { 'id' => 'alert-1', 'status' => 'resolved' }
    assert(emitter.emit(collector: 'defender_alert', raw: first, identity: 'alert-1', mutable: true), 'initial mutable event')
    assert(!emitter.emit(collector: 'defender_alert', raw: first, identity: 'alert-1', mutable: true), 'unchanged mutable event deduplicated')
    assert(emitter.emit(collector: 'defender_alert', raw: changed, identity: 'alert-1', mutable: true), 'changed mutable event')
    alert_one = mutable_queue.pop
    alert_two = mutable_queue.pop
    assert(alert_one.get('[@metadata][entity_id]') == alert_two.get('[@metadata][entity_id]'), 'mutable entity ID must be stable')
    assert(alert_one.get('[@metadata][document_id]') != alert_two.get('[@metadata][document_id]'), 'mutable version document IDs must differ')
    assert(alert_two.get('[microsoft][raw][status]') == 'resolved', 'updated raw status')
  ensure
    reopened.close
  end

  # Shutdown must release a worker blocked by a full output queue without marking
  # its record or advancing a window that Logstash never accepted.
  blocked_path = File.join(root, 'blocked-state')
  blocked_input = LogStash::Inputs::Microsoft365.new(config.merge('state_path' => blocked_path))
  blocked_input.register
  blocked_state = blocked_input.instance_variable_get(:@state)
  blocked_http = LocalHTTP.new(record.merge('id' => 'blocked-signin'))
  blocked_input.instance_variable_set(:@http, blocked_http)
  blocked_queue = SizedQueue.new(1)
  blocked_queue << :blocker
  blocked_thread = Thread.new { blocked_input.run(blocked_queue) }
  begin
    wait_until { !blocked_http.calls.empty? }
    assert(blocked_queue.length == 1, 'blocked queue must remain full before stop')
    blocked_input.stop
    blocked_thread.join(8)
    assert(!blocked_thread.alive?, 'run must stop while output queue stays full')
    blocked_thread.value
    assert(!blocked_state.seen?('signin', 'blocked-signin', 'immutable'), 'stopped blocked event must remain unseen')
    assert(blocked_state.checkpoint('signin:default:window').nil?, 'stopped blocked window must remain uncommitted')
  ensure
    if blocked_thread.alive?
      blocked_queue.pop
      blocked_thread.join(8)
    end
    blocked_input.close
  end
  blocked_reopened = Support::State.new(path: blocked_path, tenant_id: TENANT, cloud: 'commercial')
  begin
    assert(!blocked_reopened.seen?('signin', 'blocked-signin', 'immutable'), 'unaccepted event must stay unseen after H2 reopen')
    assert(blocked_reopened.checkpoint('signin:default:window').nil?, 'uncommitted window must stay absent after H2 reopen')
  ensure
    blocked_reopened.close
  end

  pfx = File.join(root, 'test.pfx')
  test_certificate(pfx)
  cert_input = LogStash::Inputs::Microsoft365.new(config.merge(
    'state_path' => File.join(root, 'certificate-state'),
    'client_secret' => nil, 'certificate_path' => pfx,
    'certificate_password' => 'test-pfx-password'
  ))
  begin
    cert_input.register
    assert(cert_input.instance_variable_get(:@auth).is_a?(Support::Auth), 'PFX must build real MSAL4J Auth')
  ensure
    cert_input.close
  end

  puts 'PASS real Logstash runtime: Base/Event, MSAL4J secret+PFX, H2 lock/reopen, backpressure and blocked shutdown, mutable updates, fields, metadata'
end
