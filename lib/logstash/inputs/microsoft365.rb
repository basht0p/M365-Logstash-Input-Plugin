# frozen_string_literal: true

require 'logstash/inputs/base'
require 'logstash/namespace'
require 'time'
require 'uri'
require_relative 'microsoft365/manifest'
require_relative 'microsoft365/auth'
require_relative 'microsoft365/http'
require_relative 'microsoft365/state'
require_relative 'microsoft365/emitter'
require_relative 'microsoft365/collectors'
require_relative 'microsoft365/hunting'

class LogStash::Inputs::Microsoft365 < LogStash::Inputs::Base
  config_name 'microsoft365'

  config :tenant_id, validate: :string, required: true
  config :client_id, validate: :string, required: true
  config :cloud, validate: %w[commercial gcc gcc_high dod], default: 'commercial'
  config :organization_id, validate: :string
  config :organization_name, validate: :string
  config :certificate_path, validate: :path
  config :certificate_password, validate: :password
  config :client_secret, validate: :password
  config :collectors, validate: :array, default: %w[activity signin directory_audit]
  config :activity_content_types, validate: :array, default: %w[Audit.Exchange Audit.SharePoint Audit.General]
  config :publisher_identifier, validate: :string
  config :include_dlp, validate: :boolean, default: false
  config :include_sensitive_dlp, validate: :boolean, default: false
  config :include_conditional_access, validate: :boolean, default: false
  config :allow_beta, validate: :boolean, default: false
  config :signin_types, validate: :array, default: %w[interactiveUser nonInteractiveUser servicePrincipal managedIdentity]
  config :hunting_queries_path, validate: :path
  config :state_path, validate: :string, required: true
  config :poll_interval, validate: :number, default: 60
  config :hunting_interval, validate: :number, default: 300
  config :risk_interval, validate: :number, default: 900
  config :initial_lookback, validate: :number, default: 86_400
  config :overlap, validate: :number, default: 900
  config :reconciliation_interval, validate: :number, default: 86_400
  config :replay_horizon, validate: :number, default: 86_400
  config :replay_from, validate: :string
  config :max_workers, validate: :number, default: 3
  config :proxy, validate: :string
  config :open_timeout, validate: :number, default: 15
  config :read_timeout, validate: :number, default: 60
  config :preserve_original, validate: :boolean, default: false
  config :ecs_compatibility, validate: %w[disabled v8], default: 'v8'

  def register
    validate_configuration!
    @stopped = false
    @health_mutex = Mutex.new
    @health = {}
    @enqueue_mutex = Mutex.new
    @enqueue_threads = []
    @state = LogStash::Inputs::Microsoft365Support::State.new(path: @state_path, tenant_id: @tenant_id, cloud: @cloud)
    cloud_config = LogStash::Inputs::Microsoft365Support::Manifest.cloud(@cloud)
    @auth = LogStash::Inputs::Microsoft365Support::Auth.new(
      tenant_id: @tenant_id, client_id: @client_id, cloud: cloud_config,
      certificate_path: @certificate_path, certificate_password: secret_value(@certificate_password),
      client_secret: secret_value(@client_secret), proxy: @proxy, timeout: @read_timeout.to_i, stop: -> { @stopped }
    )
    @http = LogStash::Inputs::Microsoft365Support::HTTP.new(
      cloud: cloud_config, auth: @auth, stop: -> { @stopped }, logger: @logger,
      proxy: @proxy, open_timeout: @open_timeout.to_i, read_timeout: @read_timeout.to_i
    )
    @config_hash = {
      tenant_id: @tenant_id, overlap: @overlap.to_i, initial_lookback: @initial_lookback.to_i,
      signin_types: effective_signin_types, activity_content_types: effective_content_types,
      publisher_identifier: @publisher_identifier, hunting_interval: @hunting_interval.to_i,
      replay_from: @replay_from, reconciliation_interval: @reconciliation_interval.to_i,
      replay_horizon: @replay_horizon.to_i
    }
  rescue StandardError
    @state&.close
    raise
  end

  def run(queue)
    metrics_mutex = Mutex.new
    metrics = {}
    metric_for = lambda do |name|
      metrics_mutex.synchronize do
        metrics[name] ||= @metric&.namespace(:microsoft365)&.namespace(name.to_s.tr('.', '_').to_sym)
      end
    end
    @http.on_retry = ->(status) { metric_for.call(Thread.current[:m365_collector])&.increment(status == 429 ? :throttles : :server_retries) }
    on_result = lambda do |name, emitted, timestamp|
      metric = metric_for.call(name)
      metric&.increment(emitted ? :emitted : :duplicates)
      if emitted && timestamp
        begin
          metric&.gauge(:lag_seconds, [Time.now.utc - Time.iso8601(timestamp.to_s), 0].max.to_i)
        rescue ArgumentError
          nil
        end
      end
    end
    emitter = LogStash::Inputs::Microsoft365Support::Emitter.new(
      queue: queue, state: @state, tenant_id: @tenant_id,
      organization_id: @organization_id, organization_name: @organization_name,
      preserve_original: @preserve_original, ecs_compatibility: @ecs_compatibility,
      on_result: on_result, decorate: ->(event) { decorate(event) },
      on_enqueue_start: -> { track_enqueue_start }, on_enqueue_commit: ->(&block) { track_enqueue_commit(&block) },
      on_enqueue_end: -> { track_enqueue_end },
      event_factory: ->(data) { LogStash::Event.new(data) }
    )
    collectors = build_collectors(emitter)
    tasks = SizedQueue.new([@max_workers.to_i * 2, 1].max)
    active = {}
    due = collectors.keys.to_h { |name| [name, Time.at(0)] }
    schedule_mutex = Mutex.new
    worker_count = [@max_workers.to_i, collectors.length].min
    workers = Array.new(worker_count) do
      Thread.new do
        until @stopped
          begin
            name = tasks.pop(true)
          rescue ThreadError
            sleep 0.1
            next
          end
          next_due = nil
          begin
            Thread.current[:m365_collector] = name
            collectors.fetch(name).run_once
            metric_for.call(name)&.increment(:runs)
            metric_for.call(name)&.gauge(:last_success_epoch, Time.now.to_i)
            metric_for.call(name)&.gauge(:healthy, 1)
            @health_mutex.synchronize { @health[name] = { status: 'ok', last_success: Time.now.utc.iso8601(3) } }
          rescue LogStash::Inputs::Microsoft365Support::QueueStopped
            # A stopped queue write has not committed source progress; replay will resume it.
          rescue StandardError => e
            metric_for.call(name)&.increment(:errors)
            pause = e.is_a?(LogStash::Inputs::Microsoft365Support::HTTPError) && [400, 401, 403, 404].include?(e.status)
            next_due = Time.now + 3600 if pause
            metric_for.call(name)&.gauge(:healthy, 0)
            @health_mutex.synchronize do
              @health[name] = { status: pause ? 'paused' : 'error', error_class: e.class.name, retry_at: next_due&.utc&.iso8601(3) }
            end
            safe_error = case e
                         when LogStash::Inputs::Microsoft365Support::HTTPError,
                              LogStash::Inputs::Microsoft365Support::ResponseTooLarge
                           e.message
                         else
                           e.class.name
                         end
            @logger.error('Microsoft 365 collector failed', collector: name, error_class: e.class.name, error: safe_error)
          ensure
            Thread.current[:m365_collector] = nil
            schedule_mutex.synchronize do
              due[name] = next_due || Time.now + interval_for(name)
              active.delete(name)
            end
            begin
              @state.prune_seen(before: Time.now - 10 * 86_400)
            rescue StandardError => prune_error
              @logger.error('Microsoft 365 state pruning failed', error_class: prune_error.class.name)
            end
          end
        end
      end
    end
    @workers = workers

    until @stopped
      now = Time.now
      schedule_mutex.synchronize do
        collectors.each_key do |name|
          next if active[name] || now < due[name]
          next if tasks.length >= tasks.max
          active[name] = true
          tasks << name
        end
      end
      sleep 0.25
    end
  ensure
    @stopped = true
    workers&.each(&:join)
  end

  def stop
    @stopped = true
    @enqueue_mutex&.synchronize do
      @enqueue_threads.uniq.each do |worker|
        worker.raise(LogStash::Inputs::Microsoft365Support::QueueStopped.new('Input stopped during queue write')) if worker.alive?
      end
    end
  end

  def health
    @health_mutex.synchronize { @health.dup }
  end

  def close
    stop
    @workers&.each { |worker| worker.join unless worker == Thread.current }
    @state&.close
  end

  private

  def track_enqueue_start
    @enqueue_mutex.synchronize do
      raise LogStash::Inputs::Microsoft365Support::QueueStopped, 'Input stopped before queue write' if @stopped
      @enqueue_threads << Thread.current
    end
  end

  def track_enqueue_end
    @enqueue_mutex.synchronize { @enqueue_threads.delete(Thread.current) }
  end

  def track_enqueue_commit
    @enqueue_mutex.synchronize do
      yield
      @enqueue_threads.delete(Thread.current)
    end
  end

  def secret_value(value)
    value.respond_to?(:value) ? value.value : value
  end

  def validate_configuration!
    raise LogStash::ConfigurationError, 'tenant_id and client_id must be UUIDs' unless [@tenant_id, @client_id].all? { |v| v.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i) }
    has_cert = @certificate_path && !@certificate_path.empty?
    has_secret = secret_value(@client_secret) && !secret_value(@client_secret).empty?
    raise LogStash::ConfigurationError, 'Choose exactly one of certificate_path or client_secret' unless has_cert != has_secret
    if has_cert
      raise LogStash::ConfigurationError, 'certificate_path must point to a readable PKCS12 .pfx or .p12 file' unless @certificate_path.match?(/\.(pfx|p12)\z/i) && ::File.file?(@certificate_path) && ::File.readable?(@certificate_path)
      raise LogStash::ConfigurationError, 'certificate_password is required for a PKCS12 file' unless secret_value(@certificate_password)
    end
    raise LogStash::ConfigurationError, 'collectors must not be empty or repeated' if @collectors.empty? || @collectors.uniq.length != @collectors.length
    unknown = @collectors - LogStash::Inputs::Microsoft365Support::Manifest.load.fetch('collectors').keys
    raise LogStash::ConfigurationError, "Unknown collectors: #{unknown.join(', ')}" unless unknown.empty?
    raise LogStash::ConfigurationError, 'signin_beta requires allow_beta => true' if @collectors.include?('signin_beta') && !@allow_beta
    allowed_types = %w[interactiveUser nonInteractiveUser servicePrincipal managedIdentity]
    raise LogStash::ConfigurationError, 'signin_types must contain valid distinct types' if @signin_types.empty? || @signin_types.uniq.length != @signin_types.length || (@signin_types - allowed_types).any?
    raise LogStash::ConfigurationError, 'signin_beta has no distinct sign-in types to collect' if @collectors.include?('signin_beta') && effective_signin_types.empty?
    raise LogStash::ConfigurationError, 'hunting requires hunting_queries_path' if @collectors.include?('hunting') && (!@hunting_queries_path || !::File.file?(@hunting_queries_path))
    raise LogStash::ConfigurationError, 'include_sensitive_dlp requires include_dlp' if @include_sensitive_dlp && !@include_dlp
    raise LogStash::ConfigurationError, 'state_path must not be empty' if @state_path.to_s.empty?
    allowed_feeds = %w[Audit.Exchange Audit.SharePoint Audit.General Audit.AzureActiveDirectory DLP.All]
    raise LogStash::ConfigurationError, 'Invalid activity_content_types' if (@activity_content_types - allowed_feeds).any?
    raise LogStash::ConfigurationError, 'activity_content_types must not be empty' if @collectors.include?('activity') && effective_content_types.empty?
    raise LogStash::ConfigurationError, 'DLP.All requires include_dlp' if @activity_content_types.include?('DLP.All') && !@include_dlp
    { poll_interval: @poll_interval, hunting_interval: @hunting_interval, risk_interval: @risk_interval,
      initial_lookback: @initial_lookback, max_workers: @max_workers, open_timeout: @open_timeout,
      read_timeout: @read_timeout, reconciliation_interval: @reconciliation_interval, replay_horizon: @replay_horizon }.each do |name, value|
      raise LogStash::ConfigurationError, "#{name} must be positive" unless value.to_i.positive?
    end
    raise LogStash::ConfigurationError, 'overlap must be from 0 to 3599 seconds' unless @overlap.to_i.between?(0, 3599)
    raise LogStash::ConfigurationError, 'max_workers must be an integer from 1 to 16' unless @max_workers.to_i == @max_workers && @max_workers.to_i.between?(1, 16)
    if @collectors.include?('activity') && (@initial_lookback.to_i > 7 * 86_400 || @replay_horizon.to_i > 7 * 86_400)
      raise LogStash::ConfigurationError, 'Activity lookback and replay horizon cannot exceed seven days'
    end
    if @replay_from
      parsed_replay = Time.iso8601(@replay_from)
      raise LogStash::ConfigurationError, 'replay_from must be in the past' if parsed_replay > Time.now
    end
    if @proxy
      uri = URI.parse(@proxy)
      raise LogStash::ConfigurationError, 'proxy must be an HTTP URL without embedded credentials' unless uri.scheme == 'http' && uri.host && uri.userinfo.nil?
    end
  rescue ArgumentError => e
    raise LogStash::ConfigurationError, e.message
  end

  def effective_signin_types
    types = @signin_types.dup
    types.delete('interactiveUser') if @collectors.include?('signin') && @collectors.include?('signin_beta')
    types
  end

  def effective_content_types
    types = @activity_content_types.dup
    types << 'DLP.All' if @include_dlp && !types.include?('DLP.All')
    types
  end

  def build_collectors(emitter)
    @collectors.to_h do |name|
      shared = { http: @http, state: @state, emitter: emitter, config: @config_hash, stop: -> { @stopped } }
      collector = case name
                  when 'activity' then LogStash::Inputs::Microsoft365Support::ActivityCollector.new(**shared)
                  when 'hunting' then LogStash::Inputs::Microsoft365Support::HuntingCollector.new(path: @hunting_queries_path, **shared)
                  else LogStash::Inputs::Microsoft365Support::GraphCollector.new(name: name, **shared)
                  end
      [name, collector]
    end
  end

  def interval_for(name)
    return @hunting_interval.to_i if name == 'hunting'
    return @risk_interval.to_i if %w[risk_detection risky_user].include?(name)
    @poll_interval.to_i
  end
end
