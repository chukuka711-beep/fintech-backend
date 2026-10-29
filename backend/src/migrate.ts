import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { Pool } from 'pg';
import { config } from './config';

async function main() {
  const pool = new Pool({
    connectionString: config.DIRECT_URL,
    ssl: config.DIRECT_URL.includes('localhost') ? false : { rejectUnauthorized: true },
    max: 1
  });
  const sql = await readFile(join(__dirname, '../migrations/001_initial.sql'), 'utf8');
  try {
    await pool.query(sql);
  } finally {
    await pool.end();
  }
}

main().catch((error: unknown) => {
  console.error('Migration failed', error instanceof Error ? error.message : 'Unknown error');
  process.exitCode = 1;
});
