FROM alpine:3.19

# Install base dependencies (ca-certificates for HTTPS networking)
RUN apk add --no-cache ca-certificates curl bash

# Define the architecture and version
ARG TARGETARCH
ARG MOONSTONE_VERSION=latest

# This simulates exactly what Bun and PNPM do!
# They do NOT compile from source in the Dockerfile. They download the pre-compiled native binary.
RUN if [ "$TARGETARCH" = "arm64" ]; then \
        ARCH="aarch64"; \
    else \
        ARCH="x86_64"; \
    fi && \
    # Remove the 'v' prefix if it exists in the version for the binary name (e.g., v0.4.0 -> 0.4.0)
    curl -fsSL "https://github.com/moonstone-sh/moonstone/releases/download/${MOONSTONE_VERSION}/moon-${ARCH}-linux-musl.tar.gz" | tar -xz -C /usr/local/bin


# Set Moonstone as the entrypoint
ENTRYPOINT ["moon"]
