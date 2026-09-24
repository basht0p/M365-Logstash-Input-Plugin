# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'time'
require 'openssl'

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
        attr_accessor :on_retry

        def initialize(cloud:, auth:, stop:, logger:, proxy: nil, open_timeout: 15, read_timeout: 60, max_retries: 5, max_body_bytes: 32 * 1024 * 1024)
          @cloud, @auth, @stop, @logger = cloud, auth, stop, logger
          @proxy, @open_timeout, @read_timeout, @max_retries, @max_body_bytes = proxy, open_timeout, read_timeout, max_retries, max_body_bytes
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
            rescue IOError, EOFError, SocketError, Timeout::Error, Errno::ECONNRESET, Errno::ETIMEDOUT => e
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
            raise HTTPError.new(status, uri.path, '') unless status.between?(200, 299)

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

        private

        class Interrupted < StandardError; end

        def perform(method, resource, uri, payload, headers)
          http = if @proxy
                   proxy_uri = URI.parse(@proxy)
                   Net::HTTP.new(uri.host, uri.port, proxy_uri.host, proxy_uri.port, proxy_uri.user, proxy_uri.password)
                 else
                   Net::HTTP.new(uri.host, uri.port)
                 end
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          http.open_timeout = @open_timeout
          http.read_timeout = @read_timeout
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
