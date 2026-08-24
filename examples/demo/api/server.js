'use strict';

// Demo API server. Deliberately waits before listening so the cockpit's
// Starting state — and a dependent project's "Waiting on api" gate — stay
// visible long enough to watch.

const http = require('http');

const port = Number(process.env.PORT || 4301);
const startupDelayMs = 2500;

const server = http.createServer((request, response) => {
  if (request.url === '/health') {
    response.writeHead(200, { 'Content-Type': 'application/json' });
    response.end('{"status":"ok","service":"api"}\n');
    return;
  }
  response.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
  response.end(`LocalWrap demo API on port ${port}\n`);
});

console.log(`api: warming up for ${startupDelayMs} ms before listening ...`);
setTimeout(() => {
  server.listen(port, '127.0.0.1', () => {
    console.log(`api: listening on http://127.0.0.1:${port}`);
  });
}, startupDelayMs);

process.on('SIGTERM', () => {
  console.log('api: SIGTERM received, shutting down');
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 500);
});
