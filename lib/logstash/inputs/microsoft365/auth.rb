# frozen_string_literal: true

require_relative 'jars'
require 'uri'
require 'timeout'

module LogStash
  module Inputs
    module Microsoft365Support
      class Auth
        class Interrupted < StandardError; end

        Jars.load!
        java_import 'com.microsoft.aad.msal4j.ConfidentialClientApplication'
        java_import 'com.microsoft.aad.msal4j.ClientCredentialFactory'
        java_import 'com.microsoft.aad.msal4j.ClientCredentialParameters'

        def initialize(tenant_id:, client_id:, cloud:, certificate_path: nil, certificate_password: nil, client_secret: nil, proxy: nil, timeout: 60, stop: -> { false })
          @cloud, @client_id, @proxy, @timeout, @stop = cloud, client_id, proxy, timeout, stop
          @authority = "https://#{cloud.fetch('authority_host')}/#{tenant_id}"
          @credential = if certificate_path
                         stream = java.io.FileInputStream.new(certificate_path)
                         begin
                           ClientCredentialFactory.createFromCertificate(stream, certificate_password.to_s)
                         ensure
                           stream.close
                         end
                       else
                         ClientCredentialFactory.createFromSecret(client_secret.to_s)
                       end
          @mutex = Mutex.new
          @client = build_client
        end

        def token(resource)
          base = @cloud.fetch("#{resource}_base_url")
          scope = java.util.Collections.singleton("#{base}/.default")
          request = ClientCredentialParameters.builder(scope).build
          client = @mutex.synchronize { @client }
          future = client.acquireToken(request)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
          loop do
            if @stop.call
              future.cancel(true)
              raise Interrupted, 'Microsoft 365 input stopped during token acquisition'
            end
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if remaining <= 0
              future.cancel(true)
              raise Timeout::Error, 'Microsoft 365 token acquisition timed out'
            end
            begin
              return future.get(([remaining, 1].min * 1000).to_i, java.util.concurrent.TimeUnit::MILLISECONDS).accessToken
            rescue Java::JavaUtilConcurrent::TimeoutException
              next
            end
          end
        end

        def invalidate
          @mutex.synchronize { @client = build_client }
        end

        private

        def build_client
          builder = ConfidentialClientApplication.builder(@client_id, @credential).authority(@authority)
          builder.connectTimeoutForDefaultHttpClient(@timeout * 1000)
          builder.readTimeoutForDefaultHttpClient(@timeout * 1000)
          if @proxy
            uri = URI.parse(@proxy)
            address = java.net.InetSocketAddress.new(uri.host, uri.port)
            builder.proxy(java.net.Proxy.new(java.net.Proxy::Type::HTTP, address))
          end
          builder.build
        end
      end
    end
  end
end
