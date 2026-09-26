FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/zeroone-server ./cmd/zeroone-server

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/zeroone-server /zeroone-server
EXPOSE 8787
USER nonroot
ENTRYPOINT ["/zeroone-server"]
