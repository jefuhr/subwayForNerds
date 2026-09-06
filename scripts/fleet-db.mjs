import { DatabaseSync } from 'node:sqlite';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';

const [action, input, output] = process.argv.slice(2);
if (!['backup', 'check'].includes(action) || !input || (action === 'backup' && !output)) {
  throw new Error('Usage: node scripts/fleet-db.mjs check <database> | backup <database> <new-snapshot>');
}
const file = resolve(input);
if (!existsSync(file)) throw new Error('Source database does not exist');
if (output && existsSync(resolve(output))) throw new Error('Destination exists; refusing to overwrite it');
const db = new DatabaseSync(file, { readOnly: true });
try {
  const result = db.prepare('PRAGMA integrity_check').all();
  if (result.length !== 1 || result[0].integrity_check !== 'ok') throw new Error('Database integrity check failed');
  if (action === 'backup') { db.prepare('VACUUM INTO ?').run(resolve(output)); console.log(`Consistent snapshot created: ${resolve(output)}`); }
  else console.log('Database integrity: ok');
} finally { db.close(); }
