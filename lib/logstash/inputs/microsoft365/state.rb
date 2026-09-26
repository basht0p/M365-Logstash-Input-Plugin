# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'digest'
require_relative 'jars'

module LogStash
  module Inputs
    module Microsoft365Support
      # Each public operation is transactional and synchronized because collectors share one H2 connection.
      # The directory lock prevents two Logstash processes from owning the same checkpoints.
      class State
        TOUCH_AFTER = 86_400
        PRUNE_BATCH = 50_000

        def initialize(path:, tenant_id:, cloud:, max_pending: 10_000)
          raise 'H2 state requires JRuby' unless defined?(JRUBY_VERSION)

          Jars.load!
          @mutex = Mutex.new
          @namespace = "#{cloud}:#{tenant_id}"
          @max_pending = max_pending
          FileUtils.mkdir_p(path)
          @lock_file = ::File.open(::File.join(path, '.microsoft365.lock'), ::File::RDWR | ::File::CREAT, 0o600)
          raise "Microsoft 365 state already owned: #{path}" unless @lock_file.flock(::File::LOCK_EX | ::File::LOCK_NB)

          db_path = ::File.join(path, 'microsoft365').tr('\\', '/')
          @connection = Java::OrgH2::Driver.new.connect("jdbc:h2:file:#{db_path};AUTO_SERVER=FALSE;DB_CLOSE_ON_EXIT=FALSE;WRITE_DELAY=0", java.util.Properties.new)
          execute('CREATE TABLE IF NOT EXISTS metadata (name VARCHAR(64) PRIMARY KEY, payload VARCHAR(512) NOT NULL)')
          owner = query_one('SELECT payload FROM metadata WHERE name=?', 'owner')&.first
          raise "Microsoft 365 state belongs to #{owner}" if owner && owner != @namespace
          execute('MERGE INTO metadata (name,payload) KEY(name) VALUES (?,?)', 'owner', @namespace)
          version = query_one('SELECT payload FROM metadata WHERE name=?', 'schema')&.first
          raise "Unsupported Microsoft 365 state schema #{version}" if version && version != '1'
          execute('MERGE INTO metadata (name,payload) KEY(name) VALUES (?,?)', 'schema', '1')
          execute('CREATE TABLE IF NOT EXISTS checkpoints (namespace VARCHAR(512) NOT NULL, name VARCHAR(512) NOT NULL, payload CLOB NOT NULL, PRIMARY KEY(namespace,name))')
          execute('CREATE TABLE IF NOT EXISTS seen (namespace VARCHAR(512) NOT NULL, name VARCHAR(512) NOT NULL, identity_hash VARCHAR(64) NOT NULL, version_hash VARCHAR(64) NOT NULL, touched_at BIGINT NOT NULL, PRIMARY KEY(namespace,name,identity_hash,version_hash))')
          execute('CREATE INDEX IF NOT EXISTS seen_touched ON seen(namespace, touched_at)')
          execute('CREATE TABLE IF NOT EXISTS pending (namespace VARCHAR(512) NOT NULL, name VARCHAR(512) NOT NULL, identity_hash VARCHAR(64) NOT NULL, payload CLOB NOT NULL, PRIMARY KEY(namespace,name,identity_hash))')
        rescue StandardError
          close
          raise
        end

        def checkpoint(name)
          @mutex.synchronize do
            query_one('SELECT payload FROM checkpoints WHERE namespace=? AND name=?', @namespace, name)&.first
          end
        end

        def set_checkpoint(name, value)
          @mutex.synchronize do
            execute('MERGE INTO checkpoints (namespace,name,payload) KEY(namespace,name) VALUES (?,?,?)', @namespace, name, value.to_s)
          end
        end

        # Writes several checkpoints in one transaction. A nil value deletes that checkpoint.
        def set_checkpoints(values)
          @mutex.synchronize do
            @connection.setAutoCommit(false)
            begin
              values.each do |name, value|
                if value.nil?
                  execute('DELETE FROM checkpoints WHERE namespace=? AND name=?', @namespace, name)
                else
                  execute('MERGE INTO checkpoints (namespace,name,payload) KEY(namespace,name) VALUES (?,?,?)', @namespace, name, value.to_s)
                end
              end
              @connection.commit
            rescue StandardError, java.sql.SQLException
              @connection.rollback
              raise
            ensure
              @connection.setAutoCommit(true)
            end
          end
        end

        # touch: extend the entry's lifetime when it was last touched more than TOUCH_AFTER seconds ago.
        def seen?(name, identity, version, touch: false)
          @mutex.synchronize do
            keys = [@namespace, name, hash(identity), hash(version)]
            found = !!query_one('SELECT version_hash FROM seen WHERE namespace=? AND name=? AND identity_hash=? AND version_hash=?', *keys)
            if found && touch
              now = Time.now.to_i
              execute('UPDATE seen SET touched_at=? WHERE namespace=? AND name=? AND identity_hash=? AND version_hash=? AND touched_at<?', now, *keys, now - TOUCH_AFTER)
            end
            found
          end
        end

        def mark_seen(name, identity, version)
          @mutex.synchronize do
            execute('MERGE INTO seen (namespace,name,identity_hash,version_hash,touched_at) KEY(namespace,name,identity_hash,version_hash) VALUES (?,?,?,?,?)', @namespace, name, hash(identity), hash(version), Time.now.to_i)
          end
        end

        # Deletes dedupe entries last touched before `before`. There is deliberately no row cap: dropping entries
        # that are still inside the overlap or reconciliation horizon re-emits their records. Deletes run in
        # batches, releasing the lock between them so collectors are not stalled. Returns the number deleted.
        def prune_seen(before:, batch: PRUNE_BATCH)
          deleted = 0
          loop do
            count = @mutex.synchronize do
              execute('DELETE FROM seen WHERE namespace=? AND touched_at<? FETCH FIRST ? ROWS ONLY', @namespace, before.to_i, batch)
            end
            deleted += count
            return deleted if count < batch
          end
        end

        def add_pending(name, identity, value)
          @mutex.synchronize do
            unless query_one('SELECT identity_hash FROM pending WHERE namespace=? AND name=? AND identity_hash=?', @namespace, name, hash(identity))
              count = query_one('SELECT COUNT(*) FROM pending WHERE namespace=? AND name=?', @namespace, name).first.to_i
              raise "Microsoft 365 pending blob limit #{@max_pending} reached for #{name}" if count >= @max_pending
            end
            execute('MERGE INTO pending (namespace,name,identity_hash,payload) KEY(namespace,name,identity_hash) VALUES (?,?,?,?)', @namespace, name, hash(identity), JSON.generate(value))
          end
        end

        def pending(name)
          @mutex.synchronize do
            query_all('SELECT identity_hash,payload FROM pending WHERE namespace=? AND name=?', @namespace, name).map { |id, value| [id, JSON.parse(value)] }
          end
        end

        def remove_pending(name, identity)
          @mutex.synchronize { execute('DELETE FROM pending WHERE namespace=? AND name=? AND identity_hash=?', @namespace, name, hash(identity)) }
        end

        def remove_pending_hash(name, identity_hash)
          @mutex.synchronize { execute('DELETE FROM pending WHERE namespace=? AND name=? AND identity_hash=?', @namespace, name, identity_hash) }
        end

        def close
          @connection&.close unless @connection&.closed?
          if @lock_file && !@lock_file.closed?
            @lock_file.flock(::File::LOCK_UN)
            @lock_file.close
          end
        end

        private

        def hash(value)
          Digest::SHA256.hexdigest(value.to_s)
        end

        def execute(sql, *values)
          statement = @connection.prepareStatement(sql)
          bind(statement, values)
          statement.executeUpdate
        ensure
          statement&.close
        end

        def query_one(sql, *values)
          query_all(sql, *values).first
        end

        def query_all(sql, *values)
          statement = @connection.prepareStatement(sql)
          bind(statement, values)
          result = statement.executeQuery
          rows = []
          columns = result.getMetaData.getColumnCount
          rows << (1..columns).map { |i| result.getString(i) } while result.next
          rows
        ensure
          result&.close
          statement&.close
        end

        def bind(statement, values)
          values.each_with_index do |value, index|
            if value.is_a?(Integer)
              statement.setLong(index + 1, value)
            else
              statement.setString(index + 1, value.to_s)
            end
          end
        end
      end
    end
  end
end
