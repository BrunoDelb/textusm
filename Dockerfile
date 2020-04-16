FROM buildkite/puppeteer
#rastasheep/alpine-node-chromium
#node:13.13.0-alpine3.10

RUN npm i -g --unsafe-perm textusm
#RUN npm i -g --unsafe-perm textusm.cli
ADD . /textusm
WORKDIR /textusm/cli
RUN npm install -g typescript
RUN npm install
RUN npm install puppeteer
RUN tsc index.ts
ENTRYPOINT ["node", "index.js", "-c", "/input/config.json"]

