# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'time'
require 'openssl'
require_relative 'errors'

module LogStash
  module Inputs
    module Microsoft365Support
      Response = Struct.new(:body, :headers, :status, keyword_init: true)

      class ResponseTooLarge < StandardError; end

      class HTTPError < StandardError
        attr_reader :status, :url

        def initialize(status, url, text)
          @status, @url = status, url
          super("Microsoft API HTTP #{status} at #{url}: #{text.to_s[0, 300]}")
        end
      end

      class HTTP
        RETRYABLE = [429, 500, 502, 503, 504].freeze
        TRANSPORT_ERRORS = [IOError, EOFError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, Errno::ECONNRESET,
                            Errno::ECONNREFUSED, Errno::ECONNABORTED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
                            Errno::EPIPE, Errno::ETIMEDOUT].freeze
        KEEP_ALIVE_SECONDS = 30
        attr_accessor :on_retry

        class Interrupted < Stopped; end

        def initialize(cloud:, auth:, stop:, logger:, proxy: nil, open_timeout: 15, read_timeout: 60, max_retries: 5, max_body_bytes: 32 * 1024 * 1024)
          @cloud, @auth, @stop, @logger = cloud, auth, stop, logger
          @proxy, @open_timeout, @read_timeout, @max_retries, @max_body_bytes = proxy, open_timeout, read_timeout, max_retries, max_body_bytes
          @connections = {}
          @connections_mutex = Mutex.new
        end

        def get(resource, path, headers: {})
          request(:get, resource, path, headers: headers)
        end

        def post(resource, path, payload, headers: {})
          request(:post, resource, path, payload: payload, headers: headers)
        end

        def request(method, resource, path, payload: nil, headers: {})
          uri = resolve(resource, path)
          tries = 0
          refreshed = false
          loop do
            raise Interrupted, 'Microsoft 365 input stopped' if @stop.call
            begin
              response, body_text = perform(method, resource, uri, payload, headers)
            rescue *TRANSPORT_ERRORS => e
              raise if tries >= @max_retries
              tries += 1
              @logger.warn('Microsoft API transport retry', error_class: e.class.name, resource: resource)
              interruptible_sleep(retry_delay(nil, tries))
              next
            end
            status = response.code.to_i
            if status == 401 && !refreshed
              refreshed = true
              @auth.invalidate
              next
            end
            if RETRYABLE.include?(status) && tries < @max_retries
              tries += 1
              @on_retry&.call(status)
              wait = retry_delay(response['Retry-After'], tries)
              @logger.warn('Microsoft API throttled or unavailable', status: status, wait_seconds: wait, resource: resource)
              interruptible_sleep(wait)
              next
            end
            raise HTTPError.new(status, uri.path, error_detail(body_text)) unless status.between?(200, 299)

            parsed = body_text.empty? ? nil : JSON.parse(body_text)
            return Response.new(body: parsed, headers: response.each_header.to_h, status: status)
          end
        rescue JSON::ParserError
          raise "Invalid Microsoft API JSON at #{uri.path}"
        end

        def resolve(resource, path)
          base = @cloud.fetch("#{resource}_base_url")
          uri = URI.join("#{base}/", path.to_s)
          allowed = URI.parse(base)
          raise ArgumentError, "Cross-cloud #{resource} URL rejected" unless uri.scheme == 'https' && uri.host == allowed.host && uri.port == allowed.port && uri.userinfo.nil? && uri.fragment.nil?
          uri
        end

        # Closes every pooled connection.
        def close
          connections = @connections_mutex.synchronize do
            all = @connections.values
            @connections.clear
            all
          end
          connections.each { |connection| finish(connection) }
        end

        private

        def perform(method, resource, uri, payload, headers)
          http = connection(uri)
          request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
          request['Authorization'] = "Bearer #{@auth.token(resource)}"
          request['Accept'] = 'application/json'
          headers.each { |k, v| request[k] = v }
          if payload
            request['Content-Type'] = 'application/json'
            request.body = JSON.generate(payload)
          end
          body_text = +''
          response = http.request(request) do |res|
            res.read_body do |chunk|
              raise ResponseTooLarge, "Microsoft API response exceeds #{@max_body_bytes} bytes at #{uri.path}" if body_text.bytesize + chunk.bytesize > @max_body_bytes
              body_text << chunk
            end
          end
          [response, body_text]
        rescue StandardError
          # The connection may hold a partially read response; never reuse it.
          discard(uri)
          raise
        end

        # One keep-alive connection per worker thread and host, so pages and blobs reuse TLS sessions.
        def connection(uri)
          key = connection_key(uri)
          existing = @connections_mutex.synchronize { @connections[key] }
          return existing if existing&.started?

          http = if @proxy
                   proxy_uri = URI.parse(@proxy)
                   Net::HTTP.new(uri.host, uri.port, proxy_uri.host, proxy_uri.port, proxy_uri.user, proxy_uri.password)
                 else
                   # nil disables Net::HTTP's http_proxy environment lookup, matching MSAL, which ignores it.
                   Net::HTTP.new(uri.host, uri.port, nil)
                 end
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          http.open_timeout = @open_timeout
          http.read_timeout = @read_timeout
          http.keep_alive_timeout = KEEP_ALIVE_SECONDS
          http.start
          @connections_mutex.synchronize { @connections[key] = http }
          http
        end

        def discard(uri)
          connection = @connections_mutex.synchronize { @connections.delete(connection_key(uri)) }
          finish(connection) if connection
        end

        def finish(connection)
          connection.finish if connection.started?
        rescue StandardError
          nil
        end

        def connection_key(uri)
          [Thread.current.object_id, uri.host, uri.port]
        end

        # Graph and the Management API return {"error":{"code":...,"message":...}}. Only the code and message are
        # kept, truncated by HTTPError; response bodies never contain record data on error.
        def error_detail(body_text)
          error = JSON.parse(body_text)['error']
          return '' unless error.is_a?(Hash)

          [error['code'], error['message']].compact.join(': ')
        rescue JSON::ParserError, TypeError, NoMethodError
          ''
        end

        def retry_delay(value, tries)
          from_server = if value&.match?(/\A\d+\z/)
                          value.to_i
                        elsif value
                          [Time.httpdate(value) - Time.now, 0].max rescue nil
                        end
          from_server ? [from_server, 0].max : [[2**tries + rand, 1].max, 120].min
        end

        def interruptible_sleep(seconds)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
          loop do
            raise Interrupted, 'Microsoft 365 input stopped' if @stop.call
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if remaining <= 0
            sleep([remaining, 0.25].min)
          end
        end
      end
    end
  end
end
