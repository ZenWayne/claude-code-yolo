# Ultra Sandbox - Generic containerized development environment
#
# Build (works in bash, cmd, and PowerShell — single line, literal args).
# HOST_USER_NAME must NOT be `root`; the Dockerfile creates a non-root user
# with this name. Set HTTP_PROXY / HTTPS_PROXY in your environment first if
# you need them, or append `--build-arg HTTP_PROXY=... --build-arg HTTPS_PROXY=...`.
#
# docker build -f ultra-sandbox.Dockerfile --build-arg HOST_USER_UID=1000 --build-arg HOST_USER_GID=1000 --build-arg HOST_USER_NAME=devuser -t ultra-sandbox .

FROM debian:bookworm-slim

ARG HOST_USER_NAME
ARG HOST_USER_UID
ARG HOST_USER_GID
ARG HTTP_PROXY
ARG HTTPS_PROXY

ENV DEBIAN_FRONTEND=noninteractive
ENV HTTP_PROXY=${HTTP_PROXY}
ENV HTTPS_PROXY=${HTTPS_PROXY}
ENV http_proxy=${HTTP_PROXY}
ENV https_proxy=${HTTPS_PROXY}

RUN echo "Host Name is: ${HOST_USER_NAME}"
RUN echo "Host UID is: ${HOST_USER_UID}"
RUN echo "Host GID is: ${HOST_USER_GID}"

# Use Aliyun mirror for Debian packages
# Remove default sources and any files in sources.list.d to ensure only Aliyun is used
RUN rm -f /etc/apt/sources.list.d/* && \
    echo "deb http://mirrors.aliyun.com/debian/ bookworm main contrib non-free non-free-firmware" > /etc/apt/sources.list && \
    echo "deb http://mirrors.aliyun.com/debian-security/ bookworm-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list && \
    echo "deb http://mirrors.aliyun.com/debian/ bookworm-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list

# Install basic development dependencies
# Use timeout and retry for network issues
RUN apt-get update || (sleep 5 && apt-get update) && \
    apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    ca-certificates \
    locales \
    openssh-client \
    vim \
    nano \
    less \
    htop \
    procps \
    sudo \
    build-essential \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Generate en_US.UTF-8 locale
RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen \
    && locale-gen en_US.UTF-8 \
    && update-locale LANG=en_US.UTF-8

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Create workspace directory with open permissions
RUN mkdir -p /workspace && chmod 777 /workspace

# Create user inside the container with the host's UID/GID
# Handle case where GID already exists
RUN if getent group ${HOST_USER_GID} > /dev/null 2>&1; then \
        EXISTING_GROUP=$(getent group ${HOST_USER_GID} | cut -d: -f1) && \
        useradd --uid ${HOST_USER_UID} --gid ${HOST_USER_GID} -m -s /bin/bash ${HOST_USER_NAME}; \
    else \
        groupadd --gid ${HOST_USER_GID} ${HOST_USER_NAME} && \
        useradd --uid ${HOST_USER_UID} --gid ${HOST_USER_GID} -m -s /bin/bash ${HOST_USER_NAME}; \
    fi

# Add user to sudoers without password
RUN echo "${HOST_USER_NAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${HOST_USER_NAME} && \
    chmod 0440 /etc/sudoers.d/${HOST_USER_NAME}

# Create .local/bin directory for the user
RUN mkdir -p /home/${HOST_USER_NAME}/.local/bin && chown -R ${HOST_USER_NAME}:${HOST_USER_GID} /home/${HOST_USER_NAME}/.local

# Switch to user
USER ${HOST_USER_NAME}

# Set working directory
WORKDIR /workspace

# Default command - start a bash shell
CMD ["/bin/bash"]
