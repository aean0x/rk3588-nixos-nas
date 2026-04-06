FROM node:22-bookworm-slim
RUN npm install -g pnpm
RUN mkdir -p /opt/node-tools && \
    echo '{"dependencies":{"@clawdbot/lobster":"latest","@playwright/mcp":"latest","@steipete/bird":"latest","playwright":"latest"}}' > /opt/node-tools/package.json && \
    cd /opt/node-tools && \
    PNPM_HOME=/usr/local/bin pnpm install && \
    for bin in node_modules/.bin/*; do \
      [ -e "$bin" ] && ln -sf "/opt/node-tools/$bin" /usr/local/bin/ || true; \
    done
