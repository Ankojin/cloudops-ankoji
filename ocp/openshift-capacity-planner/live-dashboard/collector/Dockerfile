# =============================================================
# Collector container
# Extends the existing capacity-planner image with:
#   - postgresql-client (for psql in insert_to_db.sh)
# Azure Container Apps invokes the entrypoint once per scheduled job execution.
#
# Build locally:
#   docker build -t collector \
#     --build-arg BASE_IMAGE=capacity-planner:latest \
#     -f collector/Dockerfile .
#
# Build via ACR (deploy-aro-live-dashboard.sh handles this):
#   az acr build --build-arg BASE_IMAGE=<acr>/aro-ops/capacity-planner:<IMAGE_TAG>
# =============================================================
ARG BASE_IMAGE=capacity-planner:latest
FROM ${BASE_IMAGE}

# Add postgres client
RUN apk add --no-cache postgresql-client

# Copy collector-specific scripts
WORKDIR /collector
COPY live-dashboard/collector/insert_to_db.sh    ./
COPY live-dashboard/collector/cron-entrypoint.sh ./
RUN chmod +x *.sh

VOLUME ["/planner/output"]

# Override the base image ENTRYPOINT so cron-entrypoint.sh runs directly
# (the base capacity-planner image sets ENTRYPOINT=/planner/entrypoint.sh
# which would exec run-multi-env.sh and bypass the DB insert step).
ENTRYPOINT ["/collector/cron-entrypoint.sh"]
