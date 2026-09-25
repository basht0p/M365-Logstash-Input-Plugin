# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'
require 'ipaddr'

module LogStash
  module Inputs
    module Microsoft365Support
      class QueueStopped < StandardError; end

      class Emitter
        def initialize(queue:, state:, tenant_id:, organization_id:, organization_name:, preserve_original: true, ecs_compatibility: 'v8', on_result: nil, decorate: nil, on_enqueue_start: nil, on_enqueue_commit: nil, on_enqueue_end: nil, event_factory:)
          @queue, @state, @tenant_id = queue, state, tenant_id
          @organization_id, @organization_name = organization_id, organization_name
          @preserve_original, @event_factory = preserve_original, event_factory
          @ecs_compatibility, @on_result, @decorate = ecs_compatibility, on_result, decorate
          @on_enqueue_start, @on_enqueue_commit, @on_enqueue_end = on_enqueue_start, on_enqueue_commit, on_enqueue_end
        end

        def emit(collector:, raw:, identity:, timestamp: nil, mutable: false, revision: nil)
          canonical = canonical_json(raw)
          version = mutable ? Digest::SHA256.hexdigest(canonical) : 'immutable'
          version = "#{revision}:#{version}" if revision
          if @state.seen?(collector, identity, version)
            @on_result&.call(collector, false, timestamp)
            return false
          end

          entity_id = Digest::SHA256.hexdigest([@tenant_id, collector, identity].join(':'))
          document_id = Digest::SHA256.hexdigest([entity_id, version].join(':'))
          data = { '@timestamp' => timestamp || Time.now.utc.iso8601(3),
                   'microsoft' => { 'tenant_id' => @tenant_id, 'raw' => raw },
                   'accounting' => { 'log' => { 'type' => 'microsoft_365' } } }
          if @ecs_compatibility == 'v8'
            data['event'] = { 'dataset' => "microsoft365.#{collector}", 'id' => identity.to_s, 'kind' => 'event', 'action' => collector, 'provider' => 'microsoft365', 'created' => Time.now.utc.iso8601(3) }
            data['organization'] = { 'id' => @organization_id, 'name' => @organization_name }.reject { |_, v| v.nil? || v.empty? }
            data['event']['original'] = canonical if @preserve_original
            data.delete('organization') if data['organization'].empty?
            copy_common_fields(data, raw)
          else
            data['microsoft']['dataset'] = "microsoft365.#{collector}"
            data['microsoft']['source_id'] = identity.to_s
            data['microsoft']['original'] = canonical if @preserve_original
          end
          event = @event_factory.call(data)
          event.set('[@metadata][document_id]', document_id)
          event.set('[@metadata][entity_id]', entity_id)
          @decorate&.call(event)
          begin
            @on_enqueue_start&.call
            @queue << event
            Thread.handle_interrupt(QueueStopped => :never) do
              if @on_enqueue_commit
                @on_enqueue_commit.call { @state.mark_seen(collector, identity, version) }
              else
                @state.mark_seen(collector, identity, version)
              end
            end
          ensure
            @on_enqueue_end&.call
          end
          @on_result&.call(collector, true, timestamp)
          true
        end

        private

        def canonical_json(value)
          JSON.generate(sort_hash(value))
        end

        def sort_hash(value)
          case value
          when Hash then value.keys.sort.each_with_object({}) { |key, out| out[key] = sort_hash(value[key]) }
          when Array then value.map { |item| sort_hash(item) }
          else value
          end
        end

        def copy_common_fields(data, raw)
          user = raw['userPrincipalName'] || raw['UserId'] || raw['userDisplayName']
          data['user'] = { 'name' => user } if user
          ip = parse_ip(raw['ipAddress'] || raw['ClientIP'] || raw['clientIp'])
          data['source'] = { 'ip' => ip } if ip
          device = raw['deviceDetail'] || raw['device']
          if device.is_a?(Hash)
            mapped = { 'id' => device['deviceId'] || device['id'], 'name' => device['displayName'] || device['name'] }.reject { |_, v| v.nil? }
            data['device'] = mapped unless mapped.empty?
          end
          status = raw['status']
          if status.is_a?(Hash) && status.key?('errorCode')
            data['event']['outcome'] = status['errorCode'].to_i.zero? ? 'success' : 'failure'
          elsif raw['ResultStatus']
            value = raw['ResultStatus'].to_s.downcase
            data['event']['outcome'] = 'success' if %w[success succeeded true].include?(value)
            data['event']['outcome'] = 'failure' if %w[failure failed false].include?(value)
          end
        end

        def parse_ip(value)
          return nil unless value.is_a?(String)
          candidate = value.strip
          candidate = candidate[1...candidate.index(']')] if candidate.start_with?('[') && candidate.include?(']')
          candidate = candidate.split(':', 2).first if candidate.count(':') == 1 && candidate.include?('.')
          IPAddr.new(candidate).to_s
        rescue IPAddr::InvalidAddressError
          nil
        end
      end
    end
  end
end
