FROM alpine:latest

RUN apk add --no-cache curl iproute2 iputils ca-certificates

# Download vip-manager binary from GitHub releases
ARG VIP_MANAGER_VERSION=2.6.0
RUN ARCH=$(uname -m | sed 's/x86_64/x86_64/;s/aarch64/arm64/') && \
    curl -fsSL "https://github.com/cybertec-postgresql/vip-manager/releases/download/v${VIP_MANAGER_VERSION}/vip-manager_${VIP_MANAGER_VERSION}_Linux_${ARCH}.tar.gz" \
    -o /tmp/vip-manager.tar.gz && \
    tar -xzf /tmp/vip-manager.tar.gz --strip-components=1 -C /usr/local/bin/ && \
    chmod +x /usr/local/bin/vip-manager && \
    rm /tmp/vip-manager.tar.gz

ENTRYPOINT ["vip-manager"]
