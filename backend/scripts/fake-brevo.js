// Development-only fake of the two Brevo endpoints MacGuard uses. Appends each sent mail to a JSONL file.
import http from 'node:http';
import fs from 'node:fs';
const [port, logFile] = [Number(process.argv[2] || 8798), process.argv[3] || './fake-brevo.jsonl'];
http.createServer((req, res) => {
  let b = ''; req.on('data', (c) => (b += c)); req.on('end', () => {
    const ok = req.headers['api-key'] === 'xkeysib-e2e-test-key-123';
    res.setHeader('content-type', 'application/json');
    if (!ok) { res.statusCode = 401; return res.end('{"message":"Key not found"}'); }
    if (req.url === '/v3/account') return res.end('{"email":"fake@brevo.test"}');
    if (req.url === '/v3/smtp/email') { fs.appendFileSync(logFile, b + '\n'); res.statusCode = 201; return res.end('{"messageId":"<fake>"}'); }
    res.statusCode = 404; res.end('{}');
  });
}).listen(port, '127.0.0.1', () => console.log('fake brevo on', port));
