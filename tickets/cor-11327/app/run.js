// Runs one SQL script and saves its results.   node run.js <00..06> [--dir <folder>] [--client <id>] [--fix-date <yyyy-mm-dd>] [--commit]
import fs from 'node:fs';
import path from 'node:path';
import { parseArgs } from 'node:util';
import pg from 'pg';
import { stringify } from 'csv-stringify/sync';

// Per script: database env prefix (as in the services), input files (from earlier scripts), output file.
const SCRIPTS = {
  '00': { db: 'RDS' },
  '01': { db: 'CLIENT_DB', output: 'restricted_cids.json' },
  '02': { db: 'RDS', inputs: ['restricted_cids.json'], output: 'security_hist_entity.json' },
  '03': { db: 'DB', output: 'client_rules.json' },
  '04': { db: 'CLIENT_DB', inputs: ['client_rules.json', 'security_hist_entity.json'], output: 'candidates.csv' },
  '05': { db: 'CLIENT_DB', inputs: ['client_rules.json', 'approved_status_changes.json'] },
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
  // Inputs as session settings cor11327.<name>, read in SQL with current_setting(); nothing is created in the DB.
  const settings = { client_id: opt.client, fix_date: opt['fix-date'] };
  for (const file of script.inputs ?? []) settings[path.parse(file).name] = fs.readFileSync(path.join(opt.dir, file), 'utf8');
  for (const [key, value] of Object.entries(settings)) {
    if (value !== undefined) await db.query('SELECT set_config($1, $2, false)', [`cor11327.${key}`, value]);
  }

  // Run the whole script. --commit turns the final dry-run ROLLBACK into COMMIT.
  let sql = fs.readFileSync(path.join(sqlDir, sqlFile), 'utf8');
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
    fs.writeFileSync(path.join(opt.dir, script.output), script.output.endsWith('.json') ? JSON.stringify(last.rows, null, 2) : csv(last));
  }
} finally {
  await db.end();
}
