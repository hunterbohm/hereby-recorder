FROM node:22-bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends wget ca-certificates xvfb pulseaudio pulseaudio-utils ffmpeg fonts-liberation fonts-noto-color-emoji procps xdotool \
 && wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
 && apt-get install -y --no-install-recommends ./google-chrome-stable_current_amd64.deb \
 && rm google-chrome-stable_current_amd64.deb && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev && chown -R node:node /app
COPY --chown=node:node driver.mjs start.sh ./
USER node
ENV DISPLAY=:99 HOME=/home/node
EXPOSE 8080
CMD ["/app/start.sh"]
