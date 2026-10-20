// Issues a single-use, 24h enrollment token. Only the SHA-256 of the token is stored.
import crypto from 'node:crypto';
import { Store } from '../src/store.js';
const store = new Store(process.env.DATA_DIR || './data');
const token = crypto.randomBytes(24).toString('base64url');
store.addToken(token);
console.log('Enrollment token (valid 24h, single use):\n' + token);
