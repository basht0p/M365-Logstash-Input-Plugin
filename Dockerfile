# syntax=docker/dockerfile:1
# Logstash OSS image with the microsoft365 input installed from this checkout.
#   docker build --build-arg LOGSTASH_VERSION=9.5.4 -t logstash-microsoft365 .
ARG LOGSTASH_VERSION=9.5.4

FROM --platform=$BUILDPLATFORM maven:3.9-eclipse-temurin-21 AS jars
WORKDIR /src
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -B -q dependency:copy-dependencies

# Build the gem with the JRuby that ships in the target Logstash. It shares the final stage's
# base, so a single-platform build pulls one Logstash image.
FROM --platform=$BUILDPLATFORM docker.elastic.co/logstash/logstash-oss:${LOGSTASH_VERSION} AS gem
USER root
WORKDIR /src
COPY logstash-input-microsoft365.gemspec LICENSE README.md ./
COPY lib lib
COPY data data
COPY --from=jars /src/vendor/jars vendor/jars
RUN JAVA_HOME=/usr/share/logstash/jdk /usr/share/logstash/vendor/jruby/bin/jruby -S gem build logstash-input-microsoft365.gemspec \
 && mkdir /out && mv logstash-input-microsoft365-*.gem /out/

# The OSS distribution leaves out X-Pack and the Elastic-licensed plugins, which this input doesn't use.
FROM docker.elastic.co/logstash/logstash-oss:${LOGSTASH_VERSION}
LABEL org.opencontainers.image.source="https://github.com/basht0p/M365-Logstash-Input-Plugin" \
      org.opencontainers.image.description="Logstash OSS with the microsoft365 input plugin" \
      org.opencontainers.image.licenses="Apache-2.0"
# Two malloc arenas keep glibc from growing a native heap per JVM thread.
ENV MALLOC_ARENA_MAX=2
# Between polls the pipeline is mostly idle. Start with a small heap that grows to the stock 1 GB
# maximum under load, and run a periodic G1 cycle when idle so unused heap goes back to the OS. The free
# ratios let G1 shrink the heap once less than 60% of it is in use instead of the default 30%.
# Later lines in jvm.options win, and LS_JAVA_OPTS still overrides both.
RUN --mount=type=bind,from=gem,source=/out,target=/tmp/plugin,rw \
    bin/logstash-plugin install /tmp/plugin/logstash-input-microsoft365-*.gem \
 && printf '%s\n' '' '## microsoft365 image: release idle memory' '-Xms256m' '-XX:G1PeriodicGCInterval=60000' '-XX:MinHeapFreeRatio=20' '-XX:MaxHeapFreeRatio=40' >> config/jvm.options
