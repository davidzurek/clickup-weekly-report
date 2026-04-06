FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    bash \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY docs/ ./docs/
COPY clickup-summary.sh .

RUN mkdir -p outputs && chmod +x clickup-summary.sh

ENTRYPOINT ["./clickup-summary.sh"]
