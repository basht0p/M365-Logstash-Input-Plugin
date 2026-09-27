# frozen_string_literal: true

require 'time'
require_relative 'errors'

module LogStash
  module Inputs
    module Microsoft365Support
      # Time-window cursor shared by the Graph and Activity collectors.
      #
      # The incremental cursor at `key` is the end of the last committed window; each run collects at most one
      # window forward from it. Records that arrive up to `overlap` seconds late are caught by a trailing sweep
      # that runs once per `overlap` period and re-reads `2 * overlap + poll_interval` seconds behind the cursor,
      # instead of re-reading the overlap on every poll.
      #
      # `replay_from` moves the cursor back once. Windows before the cursor's position at replay start are
      # collected with force, so records are re-emitted even when they were already delivered.
      #
      # Reconciliation re-reads `replay_horizon` once per `reconciliation_interval`, one window per run.
      #
      # A window whose collection raises WindowTooLarge is split in half and retried, down to MIN_SPLIT_SECONDS.
      class TimeWindows
        MIN_SPLIT_SECONDS = 60

        # max_age: the oldest data the source can still serve, in seconds; older windows are skipped.
        def initialize(state:, config:, clock:, max_window:, max_age: nil)
          @state, @config, @clock, @max_window, @max_age = state, config, clock, max_window, max_age
        end

        # Yields (start_at, finish_at, force) for each window to collect and commits progress afterwards.
        # Returns a description of the source gap skipped because the cursor fell behind max_age, or nil.
        def advance(key)
          now = @clock.call.utc
          force_until = start_replay(key, now)
          cursor = time_or_nil(@state.checkpoint(key))
          floor = oldest(now)
          gap = nil
          if cursor
            if floor && cursor < floor
              gap = "#{cursor.iso8601(3)} to #{floor.iso8601(3)}"
              cursor = floor
            end
            sweep(key, cursor, now, floor) { |s, f| yield s, f, false } unless force_until
            start_at = cursor
          else
            start_at = now - @config.fetch(:initial_lookback)
            start_at = floor if floor && start_at < floor
          end
          finish_at = [start_at + @max_window, now].min
          return gap if finish_at <= start_at

          force = !force_until.nil? && start_at < force_until
          split(start_at, finish_at) { |s, f| yield s, f, force }
          updates = { key => finish_at.iso8601(3) }
          updates[replay_key(key)] = 'done' if force_until && finish_at >= force_until
          @state.set_checkpoints(updates)
          gap
        end

        # Yields (start_at, finish_at) for the next reconciliation window, if one is due.
        def reconcile(group)
          now = @clock.call.utc
          cursor = time_or_nil(@state.checkpoint("#{group}:cursor"))
          if cursor
            start_at = cursor
            target = time_or_nil(@state.checkpoint("#{group}:target")) || now
          else
            last_started = time_or_nil(@state.checkpoint("#{group}:last_started"))
            return if last_started && now - last_started < @config.fetch(:reconciliation_interval)

            start_at = now - @config.fetch(:replay_horizon)
            target = now
            @state.set_checkpoints("#{group}:target" => now.iso8601(3), "#{group}:cursor" => start_at.iso8601(3),
                                   "#{group}:last_started" => now.iso8601(3))
          end
          floor = oldest(now)
          start_at = floor if floor && start_at < floor
          finish_at = [start_at + @max_window, target].min
          split(start_at, finish_at) { |s, f| yield s, f } if finish_at > start_at
          @state.set_checkpoint("#{group}:cursor", finish_at >= target ? '' : finish_at.iso8601(3))
        end

        private

        # Returns the time before which windows are forced, or nil when no replay is in progress.
        def start_replay(key, now)
          replay_from = @config[:replay_from]
          return nil unless replay_from

          status = @state.checkpoint(replay_key(key))
          return nil if status == 'done'
          return Time.iso8601(status) if status && !status.empty?

          cursor = time_or_nil(@state.checkpoint(key))
          position = cursor || now
          start_at = [Time.iso8601(replay_from), cursor || now - @config.fetch(:initial_lookback)].min
          # One transaction, so a crash cannot record the replay as started without moving the cursor.
          @state.set_checkpoints(replay_key(key) => position.iso8601(3), key => start_at.iso8601(3),
                                 sweep_key(key) => now.iso8601(3))
          position
        end

        def sweep(key, cursor, now, floor)
          overlap = @config.fetch(:overlap)
          return if overlap <= 0

          last = time_or_nil(@state.checkpoint(sweep_key(key)))
          return if last && now - last < overlap

          start_at = cursor - (2 * overlap) - @config.fetch(:poll_interval, 60)
          start_at = floor if floor && start_at < floor
          while start_at < cursor
            finish_at = [start_at + @max_window, cursor].min
            split(start_at, finish_at) { |s, f| yield s, f }
            start_at = finish_at
          end
          @state.set_checkpoint(sweep_key(key), now.iso8601(3))
        end

        def split(start_at, finish_at, &block)
          block.call(start_at, finish_at)
        rescue WindowTooLarge => e
          if finish_at - start_at <= MIN_SPLIT_SECONDS
            raise WindowTooLarge, "#{e.message}; window #{start_at.iso8601(3)} to #{finish_at.iso8601(3)} cannot be split further"
          end

          midpoint = Time.at((start_at.to_r + finish_at.to_r) / 2).utc
          split(start_at, midpoint, &block)
          split(midpoint, finish_at, &block)
        end

        def oldest(now)
          @max_age && now - @max_age
        end

        def time_or_nil(text)
          text && !text.empty? ? Time.iso8601(text) : nil
        end

        def replay_key(key)
          "#{key}:replay:#{@config[:replay_from]}"
        end

        def sweep_key(key)
          "#{key}:sweep"
        end
      end
    end
  end
end
