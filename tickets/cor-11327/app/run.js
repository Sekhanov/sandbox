// Runs one SQL script and saves each result as CSV.   node run.js <00..06> [--dir <folder>] [--client <id>] [--fix-date <yyyy-mm-dd>] [--commit]
import fs from 'node:fs';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { pipeline } from 'node:stream/promises';
import pg from 'pg';
import { from as copyFrom } from 'pg-copy-streams';
import { stringify } from 'csv-stringify/sync';

// Per script: database env prefix (as in the services), input CSV files (temp table -> file), output file.
const SCRIPTS = {
  '00': { db: 'RDS' },
  '01': { db: 'CLIENT_DB', output: 'restricted_cids.csv' },
  '02': { db: 'RDS', output: 'security_hist_entity.csv', inputs: { restricted_cids: 'restricted_cids.csv' } },
  '03': { db: 'DB', output: 'client_rules.json' },
  '04': { db: 'CLIENT_DB', output: 'candidates.csv', inputs: { ref_sec_hist: 'security_hist_entity.csv' } },
  '05': { db: 'CLIENT_DB', inputs: { approved: 'approved_status_changes.csv' } },
  '06': { db: 'CLIENT_DB' },
};

process.loadEnvFile(path.join(import.meta.dirname, '.env'));
for (const oid of [1082, 1114]) pg.types.setTypeParser(oid, (v) => v); // date and timestamp as text

const { values: opt, positionals: [name] } = parseArgs({
  allowPositionals: true,
  options: { dir: { type: 'string', default: path.join(import.meta.dirname, '..', 'out') }, client: { type: 'string' }, 'fix-date': { type: 'string' }, commit: { type: 'boolean' } },
});
const script = SCRIPTS[name];
if (!script) {
  console.error('Usage: npm run <00..06> -- [--dir <folder>] [--client <id>] [--fix-date <yyyy-mm-dd>] [--commit]   (default dir: ../out)');
  process.exit(1);
}

const sqlDir = path.join(import.meta.dirname, '..');
const sqlFile = fs.readdirSync(sqlDir).find((f) => f.startsWith(`${name}_`));
const csv = (r) => stringify(r.rows, { header: true, columns: r.fields.map((f) => f.name), cast: { boolean: String, object: JSON.stringify } });
fs.mkdirSync(path.join(opt.dir, 'steps'), { recursive: true });

const env = (key) => process.env[`${script.db}_${key}`];
const db = new pg.Client({ host: env('HOST'), port: env('PORT'), database: env('DATABASE') ?? env('NAME'), user: env('USERNAME'), password: env('PASSWORD') });
await db.connect();
try {
  // Input CSV files -> temp tables with text columns named after the header row.
  for (const [table, file] of Object.entries(script.inputs ?? {})) {
    const header = fs.readFileSync(path.join(opt.dir, file), 'utf8').split(/\r?\n/)[0].split(',');
    await db.query(`CREATE TEMP TABLE ${table} (${header.map((c) => `${db.escapeIdentifier(c.trim())} text`).join(', ')})`);
    await pipeline(fs.createReadStream(path.join(opt.dir, file)), db.query(copyFrom(`COPY ${table} FROM STDIN (FORMAT csv, HEADER)`)));
  }

  // Fill in the placeholders and run the whole script. --commit turns the final dry-run ROLLBACK into COMMIT.
  let sql = fs.readFileSync(path.join(sqlDir, sqlFile), 'utf8')
    .replaceAll("'<CLIENT_ID>'", () => db.escapeLiteral(opt.client))
    .replaceAll("'<FIX_DATE>'", () => db.escapeLiteral(opt['fix-date']))
    .replaceAll("'<CLIENT_RULES_JSON>'", () => db.escapeLiteral(fs.readFileSync(path.join(opt.dir, 'client_rules.json'), 'utf8')));
  if (opt.commit) sql = sql.replace(/ROLLBACK;\s*$/, 'COMMIT;');
  const results = [].concat(await db.query(sql)).filter((r) => r.fields.length);

  // Print and save each result; the last one is also the output file.
  results.forEach((r, i) => {
    const file = path.join(opt.dir, 'steps', `${name}.${i + 1}.csv`);
    fs.writeFileSync(file, csv(r));
    console.log(`\n${file}: ${r.rows.length} rows`);
    console.table(r.rows.slice(0, 20));
  });
  const last = results.at(-1);
  if (script.output && last) {
    fs.writeFileSync(path.join(opt.dir, script.output), script.output.endsWith('.json') ? Object.values(last.rows[0] ?? {})[0] ?? '' : csv(last));
  }
} finally {
  await db.end();
}
