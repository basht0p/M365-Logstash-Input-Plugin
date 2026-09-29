# syntax=docker/dockerfile:1
# Official Logstash image with the microsoft365 input installed from this checkout.
#   docker build --build-arg LOGSTASH_VERSION=9.5.4 -t logstash-microsoft365 .
ARG LOGSTASH_VERSION=9.5.4

FROM --platform=$BUILDPLATFORM maven:3.9-eclipse-temurin-21 AS jars
WORKDIR /src
COPY pom.xml .
RUN mvn -B -q dependency:copy-dependencies

# Build the gem with the JRuby that ships in the target Logstash.
FROM --platform=$BUILDPLATFORM docker.elastic.co/logstash/logstash:${LOGSTASH_VERSION} AS gem
USER root
WORKDIR /src
COPY logstash-input-microsoft365.gemspec LICENSE README.md ./
COPY lib lib
COPY data data
COPY --from=jars /src/vendor/jars vendor/jars
RUN JAVA_HOME=/usr/share/logstash/jdk /usr/share/logstash/vendor/jruby/bin/jruby -S gem build logstash-input-microsoft365.gemspec \
 && mkdir /out && mv logstash-input-microsoft365-*.gem /out/

FROM docker.elastic.co/logstash/logstash:${LOGSTASH_VERSION}
LABEL org.opencontainers.image.source="https://github.com/basht0p/M365-Logstash-Input-Plugin" \
      org.opencontainers.image.description="Logstash with the microsoft365 input plugin" \
      org.opencontainers.image.licenses="Apache-2.0"
RUN --mount=type=bind,from=gem,source=/out,target=/tmp/plugin,rw \
    bin/logstash-plugin install /tmp/plugin/logstash-input-microsoft365-*.gem
