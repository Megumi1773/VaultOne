# VaultOne 同步服务镜像（多阶段构建，运行时为 distroless，非 root）
#   docker build -f deploy/Dockerfile -t vaultone/server:1.0.0 .
FROM rust:1.91-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
# app/rust（Flutter 桥）是工作区成员：只拷贝清单并放空源文件，满足 --locked 解析，但不会被编译
COPY app/rust/Cargo.toml ./app/rust/Cargo.toml
RUN mkdir -p app/rust/src && touch app/rust/src/lib.rs
RUN cargo build --release --locked -p vault-server

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /src/target/release/vault-server /usr/local/bin/vault-server
USER nonroot
EXPOSE 8787
ENV VAULTONE_BIND=0.0.0.0:8787 VAULTONE_LOG_FORMAT=json
HEALTHCHECK NONE
ENTRYPOINT ["/usr/local/bin/vault-server"]
