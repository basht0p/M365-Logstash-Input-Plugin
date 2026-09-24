#!/bin/sh
set -eu

cd /work
export LOGSTASH_HOME=/usr/share/logstash
export JAVA_HOME=/usr/share/logstash/jdk
JRUBY_VERSION="$(/usr/share/logstash/vendor/jruby/bin/jruby -e 'print RbConfig::CONFIG["ruby_version"]')"
export GEM_PATH="/root/.local/share/gem/jruby/$JRUBY_VERSION:/usr/share/logstash/vendor/jruby/lib/ruby/gems/shared:/usr/share/logstash/vendor/bundle/jruby/$JRUBY_VERSION"
exec /usr/share/logstash/vendor/jruby/bin/jruby test/integration/runtime_smoke.rb
