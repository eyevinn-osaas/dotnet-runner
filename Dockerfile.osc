ARG DOTNET_SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:8.0-alpine
ARG RUNTIME_IMAGE=mcr.microsoft.com/dotnet/aspnet:8.0-alpine

FROM node:20-alpine AS loading-stage
WORKDIR /loading
COPY scripts/loading-server.js scripts/loading-page.html scripts/error-page.html ./

FROM ${DOTNET_SDK_IMAGE} AS sdk-stage

FROM ${RUNTIME_IMAGE}
RUN apk add --no-cache bash git curl jq nodejs npm
COPY --from=sdk-stage /usr/share/dotnet /usr/share/dotnet
ENV PATH="/usr/share/dotnet:${PATH}"
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
COPY --from=loading-stage /loading /runner/
WORKDIR /runner
COPY scripts/docker-entrypoint.sh ./
RUN chmod +x /runner/docker-entrypoint.sh
VOLUME /usercontent
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/runner/docker-entrypoint.sh"]
