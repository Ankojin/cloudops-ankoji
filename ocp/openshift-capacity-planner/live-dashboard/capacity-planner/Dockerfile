# ============================================================
# OpenShift Capacity Planner — Container Image
#
# The scripts (run.sh, run-multi-env.sh, etc.) live at the
# PLANNER ROOT and are shared with the normal script workflow.
# This Dockerfile only adds the container entry-point wrapper.
#
# Build (always run from the PLANNER ROOT, not from live-dashboard/capacity-planner/):
#   cd openshift-capacity-planner
#   docker build -f live-dashboard/capacity-planner/Dockerfile -t capacity-planner .
#
# Run locally (test):
#   docker run --rm \
#     -v $(pwd)/output:/planner/output \
#     -e DEV_TOKEN=sha256~xxx \
#     -e DEV_API=https://api.dev.example.com:6443 \
#     -e SIT_TOKEN=sha256~yyy \
#     -e SIT_API=https://api.sit.example.com:6443 \
#     capacity-planner
# ============================================================

FROM alpine:3.20

# Install runtime dependencies
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    python3 \
    ca-certificates \
    gawk \
    tar \
    gzip \
    gcompat \
    libc6-compat

# Install OpenShift CLI (oc) — binary pre-downloaded into build context
# to avoid busybox tar / network issues in ACR build agents.
# Refresh locally: curl -sSLf https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz | tar -xz -C live-dashboard/capacity-planner/ oc
COPY live-dashboard/capacity-planner/oc /usr/local/bin/oc
RUN chmod +x /usr/local/bin/oc && oc version --client

# Copy planner scripts from the root build context
# (same files used by the normal script workflow — no duplication)
WORKDIR /planner
COPY *.sh                      ./
COPY assets/                   ./assets/

# Copy the container-specific entrypoint from the capacity-planner subfolder
COPY live-dashboard/capacity-planner/entrypoint.sh   ./entrypoint.sh

RUN chmod +x *.sh

# Output volume — mount Azure File Share here
VOLUME ["/planner/output"]

# Entrypoint reads DEV_TOKEN, DEV_API, SIT_TOKEN, SIT_API from env
# (injected as Container App Job secrets)
ENTRYPOINT ["/planner/entrypoint.sh"]
