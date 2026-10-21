# =============================================================================
# Stage 1: Build & Dependencies Layer
# =============================================================================
FROM python:3.11-slim AS builder

WORKDIR /build
COPY requirements.txt .

RUN apt-get update && apt-get install -y --no-install-recommends gcc libpq-dev \
 && pip install --no-cache-dir --prefix=/install -r requirements.txt \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# =============================================================================
# Stage 2: Hardened, Non-Root Production Runtime Layer
# =============================================================================
FROM python:3.11-slim AS runtime

LABEL maintainer="Ankit Kumar Mishra <theankitmishraa@gmail.com>"
LABEL org.opencontainers.image.title="Cloud Log Analytics Service"
LABEL org.opencontainers.image.description="Hardened, production-grade cloud log ingestion and real-time analytics container"
LABEL org.opencontainers.image.authors="Ankit Kumar Mishra"

# Security Hardening: Dedicated non-root system user and group (no interactive shell)
RUN groupadd -r -g 1001 appgroup \
 && useradd -r -u 1001 -g appgroup -s /sbin/nologin -d /app appuser

# Copy pre-compiled dependencies from builder
COPY --from=builder /install /usr/local

# Install minimal runtime requirements
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl libpq5 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy application source & dashboard static assets with strict ownership
COPY --chown=appuser:appgroup src/ /app/src/
COPY --chown=appuser:appgroup static/ /app/static/

# Drop privileges to non-root user
USER appuser

EXPOSE 8080

# Production Healthcheck Probe
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS http://localhost:8080/health || exit 1

# Direct binary exec entrypoint (no shell wrapper)
ENTRYPOINT ["python", "-m", "uvicorn", "src.main:app", \
            "--host", "0.0.0.0", "--port", "8080", \
            "--workers", "2", "--access-log"]
