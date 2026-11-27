FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 GOOS="$TARGETOS" GOARCH="$TARGETARCH" go build -trimpath -o /s3-cache .

FROM nginx:stable-alpine
LABEL org.opencontainers.image.source="https://github.com/gizlet/gizlet-mirror"
RUN apk add --no-cache bash su-exec
COPY --from=build /s3-cache /usr/local/bin/s3-cache
COPY --chmod=755 start.sh render.sh /usr/local/bin/
COPY nginx.conf.template /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/start.sh"]
