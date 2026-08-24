'use strict';

// Demo web server. Listens immediately; in the manifest it depends on the
// api project, so a workspace start holds it until the API is Ready.

const http = require('http');

const port = Number(process.env.PORT || 4302);

const server = http.createServer((request, response) => {
  if (request.url === '/health') {
    response.writeHead(200, { 'Content-Type': 'application/json' });
    response.end('{"status":"ok","service":"web"}\n');
    return;
  }
  response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  response.end(`<!doctype html>
<html lang="en">
  <head><meta charset="utf-8" /><title>LocalWrap Demo Web</title></head>
  <body>
    <h1>LocalWrap demo web on port ${port}</h1>
    <p>Started after the <a href="http://localhost:4301">API</a> became ready.</p>
  </body>
</html>
`);
});

server.listen(port, '127.0.0.1', () => {
  console.log(`web: listening on http://127.0.0.1:${port}`);
});

process.on('SIGTERM', () => {
  console.log('web: SIGTERM received, shutting down');
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 500);
});
