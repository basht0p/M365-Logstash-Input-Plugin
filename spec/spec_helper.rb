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

class FakeState
  attr_reader :checkpoints, :pending_blobs

  def initialize
    @checkpoints = {}
    @seen = {}
    @pending_blobs = Hash.new { |h, k| h[k] = {} }
  end

  def checkpoint(name) = @checkpoints[name]
  def set_checkpoint(name, value) = @checkpoints[name] = value
  def seen?(name, identity, version) = @seen.key?([name, identity, version])
  def mark_seen(name, identity, version) = @seen[[name, identity, version]] = true
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
