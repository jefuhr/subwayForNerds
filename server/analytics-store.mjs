import { DatabaseSync } from 'node:sqlite';
const day = timestamp => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(timestamp));
export class AnalyticsStore {
  constructor(file, now = Date.now()) {
    this.db = new DatabaseSync(file);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA busy_timeout=3000;
      CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, browser TEXT NOT NULL, session TEXT NOT NULL, name TEXT NOT NULL, station TEXT, device TEXT NOT NULL, referrer TEXT NOT NULL, time INTEGER NOT NULL, day TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS analytics_time ON events(time);
      CREATE INDEX IF NOT EXISTS analytics_browser ON events(browser, name, time);
      CREATE UNIQUE INDEX IF NOT EXISTS analytics_session ON events(session) WHERE name='session_start';
      CREATE TABLE IF NOT EXISTS meta(start INTEGER NOT NULL);`);
    if (!this.db.prepare('SELECT start FROM meta').get()) this.db.prepare('INSERT INTO meta VALUES(?)').run(now);
    this.cleanup(now);
  }
  cleanup(now) { this.db.prepare('DELETE FROM events WHERE time < ?').run(now - 365 * 86400000); }
  record(events, now = Date.now()) {
    this.db.exec('BEGIN');
    try {
      this.cleanup(now);
      const insert = this.db.prepare('INSERT OR IGNORE INTO events VALUES(?,?,?,?,?,?,?,?,?)');
      for (const e of events) insert.run(e.id, e.browser, e.session, e.name, e.station || null, e.device, e.referrer, now, day(now));
      this.db.exec('COMMIT');
    } catch (e) { this.db.exec('ROLLBACK'); throw e; }
  }
  stats(range, now = Date.now()) {
    this.cleanup(now);
    const days = { today: 1, '7d': 7, '30d': 30, '365d': 365 }[range];
    const end = day(now);
    const date = new Date(end + 'T12:00:00Z'); date.setUTCDate(date.getUTCDate() - days + 1);
    const start = date.toISOString().slice(0, 10);
    const scalar = (sql, ...args) => this.db.prepare(sql).get(...args).count;
    const sessions = "name='session_start' AND day>=?";
    const breakdown = (column, condition) => this.db.prepare(`SELECT ${column} AS label, COUNT(*) AS count FROM events WHERE day>=? AND ${condition} GROUP BY ${column} ORDER BY count DESC, label LIMIT 100`).all(start);
    const rows = this.db.prepare("SELECT day AS date, SUM(name='session_start') AS visits, SUM(name='station_view') AS views FROM events WHERE day>=? GROUP BY day").all(start);
    const daily = [];
    for (let i = 0; i < days; i++) { const d = date.toISOString().slice(0, 10); daily.push(rows.find(row => row.date === d) || { date: d, visits: 0, views: 0 }); date.setUTCDate(date.getUTCDate() + 1); }
    return { range, collectedSince: this.db.prepare('SELECT start FROM meta').get().start, updatedAt: now,
      visits: scalar(`SELECT COUNT(*) AS count FROM events WHERE ${sessions}`, start),
      browsers: scalar('SELECT COUNT(DISTINCT browser) AS count FROM events WHERE day>=?', start),
      returning: scalar(`SELECT COUNT(DISTINCT e.browser) AS count FROM events e WHERE e.day>=? AND EXISTS(SELECT 1 FROM events p WHERE p.name='session_start' AND p.browser=e.browser AND p.session<>e.session AND p.time<e.time)`, start),
      views: scalar("SELECT COUNT(*) AS count FROM events WHERE name='station_view' AND day>=?", start), daily,
      stations: breakdown('station', "name='station_view'"), devices: breakdown('device', "name='session_start'"), referrers: breakdown("CASE WHEN referrer='' THEN 'Direct / unknown' ELSE referrer END", "name='session_start'"),
      interactions: breakdown('name', "name NOT IN ('session_start','station_view')") };
  }
  close() { this.db.close(); }
}
