FROM nginx:1.27-alpine

# Install gettext for envsubst
RUN apk add --no-cache gettext

# Copy nginx config template (uses ${API_UPSTREAM} placeholder)
COPY nginx.conf /etc/nginx/templates/default.conf.template

# Copy the SPA
COPY index.html /usr/share/nginx/html/index.html

# Default upstream host — overridden at deploy time via API_UPSTREAM_HOST env var.
# In Azure Container Apps the API app is reachable at <app>.internal.<env-domain>
# In Docker Compose it is reachable at api (port 443 not needed — nginx adds https://)
ENV API_UPSTREAM_HOST=api

EXPOSE 80

# nginx:alpine official image processes /etc/nginx/templates/*.template
# with envsubst automatically before starting nginx
CMD ["nginx", "-g", "daemon off;"]
