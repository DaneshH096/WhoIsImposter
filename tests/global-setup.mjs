import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export default async function globalSetup() {
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'dist');
  const mime = {
    '.css': 'text/css; charset=utf-8',
    '.html': 'text/html; charset=utf-8',
    '.ico': 'image/x-icon',
    '.js': 'text/javascript; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.svg': 'image/svg+xml',
  };
  const server = createServer(async (request, response) => {
    try {
      const pathname = decodeURIComponent(new URL(request.url ?? '/', 'http://localhost').pathname);
      const requested = path.resolve(root, `.${pathname}`);
      const safePath = requested.startsWith(`${root}${path.sep}`) || requested === root;
      let file = safePath ? requested : path.join(root, 'index.html');
      try {
        if ((await stat(file)).isDirectory()) file = path.join(file, 'index.html');
      } catch {
        file = path.join(root, 'index.html');
      }
      response.writeHead(200, { 'Content-Type': mime[path.extname(file)] ?? 'application/octet-stream' });
      response.end(await readFile(file));
    } catch {
      response.writeHead(404);
      response.end('Not found');
    }
  });

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(4173, '127.0.0.1', resolve);
  });

  return () => new Promise((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve());
  });
}
