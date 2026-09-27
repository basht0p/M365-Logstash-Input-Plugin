# frozen_string_literal: true

require 'rspec'
require 'tmpdir'
require 'json'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'logstash/inputs/microsoft365/manifest'
require 'logstash/inputs/microsoft365/collectors'
require 'logstash/inputs/microsoft365/hunting'
require 'logstash/inputs/microsoft365/emitter'
require 'logstash/inputs/microsoft365/state'
require 'logstash/inputs/microsoft365/http'

RSpec.configure do |config|
  # Volume specs take tens of seconds against real H2; CI runs them as a separate step.
  config.filter_run_excluding volume: true unless ENV['M365_VOLUME']
end

class FakeState
  attr_reader :checkpoints, :pending_blobs, :touches

  def initialize
    @checkpoints = {}
    @seen = {}
    @touches = Hash.new(0)
    @pending_blobs = Hash.new { |h, k| h[k] = {} }
  end

  def checkpoint(name) = @checkpoints[name]
  def set_checkpoint(name, value) = @checkpoints[name] = value

  def set_checkpoints(values)
    values.each { |name, value| value.nil? ? @checkpoints.delete(name) : @checkpoints[name] = value.to_s }
  end

  def seen?(name, identity, version, touch: false)
    found = @seen.key?([name, identity, version])
    @touches[[name, identity]] += 1 if found && touch
    found
  end

  def mark_seen(name, identity, version) = @seen[[name, identity, version]] = true
  def forget_seen = @seen.clear
  def add_pending(name, identity, value) = @pending_blobs[name][identity] = value
  def pending(name) = @pending_blobs[name].to_a
  def remove_pending_hash(name, identity) = @pending_blobs[name].delete(identity)
end

class FakeEvent
  attr_reader :data, :metadata

  def initialize(data)
    @data = data
    @metadata = {}
  end

  def set(path, value)
    @metadata[path] = value
  end
end

class FakeHTTP
  attr_reader :calls

  def initialize(&handler)
    @handler = handler
    @calls = []
  end

  def get(resource, url)
    @calls << [:get, resource, url]
    @handler.call(:get, resource, url, nil)
  end

  def post(resource, url, body)
    @calls << [:post, resource, url, body]
    @handler.call(:post, resource, url, body)
  end
end

def response(body, headers = {})
  LogStash::Inputs::Microsoft365Support::Response.new(body: body, headers: headers, status: 200)
end

def emitter(state, queue)
  LogStash::Inputs::Microsoft365Support::Emitter.new(queue: queue, state: state, tenant_id: 'tenant', organization_id: 'org', organization_name: 'Org', event_factory: ->(data) { FakeEvent.new(data) })
end
