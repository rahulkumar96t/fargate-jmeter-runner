# syntax=docker/dockerfile:1
#
# JMeter injector/report image. Build from the repository root:
#   docker build -f docker/Dockerfile -t jmeter-runner:5.6.3 .
# For ARM64 (Graviton) tasks add --platform linux/arm64 and set cpu_architecture = "ARM64".

ARG TEMURIN_IMAGE=eclipse-temurin:21.0.13_9-jre-noble

# The AWS CLI v2 bundle is self-contained (it ships its own Python); take it from the
# official image instead of installing pip packages into the JMeter image.
FROM amazon/aws-cli:2.38.6 AS awscli

# ---------------------------------------------------------------------------------
FROM ${TEMURIN_IMAGE} AS jmeter

ARG JMETER_VERSION=5.6.3
# From https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-5.6.3.tgz.sha512
ARG JMETER_SHA512=5978a1a35edb5a7d428e270564ff49d2b1b257a65e17a759d259a9283fc17093e522fe46f474a043864aea6910683486340706d745fcdf3db1505fd71e689083
ARG PLUGINS_MANAGER_VERSION=2.0
ARG PLUGINS_MANAGER_SHA256=bc5a9916da44b19f26dada0a09fd7df17f60026dc5d71d30e6f983ef515fa99d
ARG CMDRUNNER_VERSION=2.3
ARG CMDRUNNER_SHA256=f7674154e38428e6bab0261c7dc8af1b9c59f241df4d58a077462432b8fac64e

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# JMeter itself, verified against the SHA-512 published by the Apache JMeter project.
RUN curl -fsSL --retry 3 -o /tmp/jmeter.tgz \
      "https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-${JMETER_VERSION}.tgz" \
 && echo "${JMETER_SHA512}  /tmp/jmeter.tgz" | sha512sum -c - \
 && tar -xzf /tmp/jmeter.tgz -C /opt \
 && mv "/opt/apache-jmeter-${JMETER_VERSION}" /opt/apache-jmeter \
 && rm -rf /tmp/jmeter.tgz /opt/apache-jmeter/docs /opt/apache-jmeter/printable_docs

# Plugins Manager and its command-line runner from Maven Central, pinned by SHA-256.
RUN curl -fsSL --retry 3 -o "/opt/apache-jmeter/lib/ext/jmeter-plugins-manager-${PLUGINS_MANAGER_VERSION}.jar" \
      "https://repo1.maven.org/maven2/kg/apc/jmeter-plugins-manager/${PLUGINS_MANAGER_VERSION}/jmeter-plugins-manager-${PLUGINS_MANAGER_VERSION}.jar" \
 && echo "${PLUGINS_MANAGER_SHA256}  /opt/apache-jmeter/lib/ext/jmeter-plugins-manager-${PLUGINS_MANAGER_VERSION}.jar" | sha256sum -c - \
 && curl -fsSL --retry 3 -o "/opt/apache-jmeter/lib/cmdrunner-${CMDRUNNER_VERSION}.jar" \
      "https://repo1.maven.org/maven2/kg/apc/cmdrunner/${CMDRUNNER_VERSION}/cmdrunner-${CMDRUNNER_VERSION}.jar" \
 && echo "${CMDRUNNER_SHA256}  /opt/apache-jmeter/lib/cmdrunner-${CMDRUNNER_VERSION}.jar" | sha256sum -c - \
 && java -cp "/opt/apache-jmeter/lib/ext/jmeter-plugins-manager-${PLUGINS_MANAGER_VERSION}.jar" \
      org.jmeterplugins.repository.PluginManagerCMDInstaller

# Plugins listed in plugins.txt (id=version). The Plugins Manager downloads them from
# Maven Central over HTTPS; their versions are pinned, their hashes are not.
COPY docker/plugins.txt /tmp/plugins.txt
RUN plugins="$(grep -Ev '^[[:space:]]*(#|$)' /tmp/plugins.txt | paste -sd, -)" \
 && if [[ -n "${plugins}" ]]; then /opt/apache-jmeter/bin/PluginsManagerCMD.sh install "${plugins}"; fi \
 && /opt/apache-jmeter/bin/PluginsManagerCMD.sh status \
 && rm -rf /tmp/*  # installer logs and a copy of the manager jar

# ---------------------------------------------------------------------------------
FROM ${TEMURIN_IMAGE}

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 jmeter \
 && useradd --uid 10001 --gid 10001 --home-dir /work --no-create-home --shell /usr/sbin/nologin jmeter \
 && mkdir -p /work \
 && chown 10001:10001 /work

COPY --from=awscli /usr/local/aws-cli/ /usr/local/aws-cli/
RUN ln -s /usr/local/aws-cli/v2/current/bin/aws /usr/local/bin/aws \
 && aws --version

COPY --from=jmeter /opt/apache-jmeter /opt/apache-jmeter
COPY --chmod=0755 docker/entrypoint.sh /opt/runner/entrypoint.sh
COPY --chmod=0644 docker/runner.properties tools/jtl_summary.py /opt/runner/

# HEAP is read by bin/jmeter. Sizing the heap as a share of the container's memory
# means a larger injector size gets a larger heap without a new image.
# With a read-only root file system /work is the only writable path, so temporary
# files (JVM, report generator, Python) go there too.
ENV JMETER_HOME=/opt/apache-jmeter \
    PATH=/opt/apache-jmeter/bin:${PATH} \
    HOME=/work \
    TMPDIR=/work/tmp \
    JVM_ARGS="-Djava.io.tmpdir=/work/tmp" \
    PYTHONDONTWRITEBYTECODE=1 \
    HEAP="-XX:InitialRAMPercentage=50.0 -XX:MaxRAMPercentage=75.0"

USER 10001:10001
WORKDIR /work
# ECS copies a VOLUME path's content and ownership into the Fargate bind mount at the
# same containerPath (default would be root-owned 0755), so the non-root user can
# write here while the root file system stays read-only.
VOLUME ["/work"]

ENTRYPOINT ["/opt/runner/entrypoint.sh"]
CMD ["run"]
