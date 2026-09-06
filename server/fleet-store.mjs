import { DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';

const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex').slice(0, 24);
const family = type => /^R160[AB]?$/.test(type || '') ? 'R160' : type;
const source = 'https://data.ny.gov/d/kir5-i9xt';
export class FleetStore {
  constructor(file) {
    this.current = new Map();
    this.db = new DatabaseSync(file);
    if (this.db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='migrations'").get()) {
      const version = this.db.prepare('SELECT MAX(version) AS v FROM migrations').get().v;
      if (version !== 1) { this.db.close(); throw new Error('Unsupported fleet schema; restore a compatible backup'); }
    }
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=3000;
      CREATE TABLE IF NOT EXISTS migrations(version INTEGER PRIMARY KEY);
      CREATE TABLE IF NOT EXISTS cars(id TEXT PRIMARY KEY, data TEXT NOT NULL, last TEXT, signature TEXT);
      CREATE TABLE IF NOT EXISTS assertions(id TEXT PRIMARY KEY, car_id TEXT NOT NULL, data TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS consists(id TEXT PRIMARY KEY, data TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, timestamp INTEGER NOT NULL, data TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS event_cars(event_id TEXT REFERENCES events(id) ON DELETE CASCADE, car_id TEXT, PRIMARY KEY(event_id, car_id));
      CREATE INDEX IF NOT EXISTS event_car_lookup ON event_cars(car_id);
      CREATE INDEX IF NOT EXISTS event_time ON events(timestamp);
      CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, data TEXT NOT NULL);
      INSERT OR IGNORE INTO migrations VALUES(1);`);
    if (this.db.prepare('SELECT MAX(version) AS v FROM migrations').get().v !== 1) throw new Error('Unsupported fleet schema; restore a compatible backup');
  }
  transaction(fn) {
    this.db.exec('BEGIN IMMEDIATE');
    try { const result = fn(); this.db.exec('COMMIT'); return result; }
    catch (e) { this.db.exec('ROLLBACK'); throw e; }
  }
  meta(key, data) { this.db.prepare('INSERT OR REPLACE INTO meta VALUES(?,?)').run(key, JSON.stringify(data)); }
  importRoster(rows, date, minimum = 4000) {
    if (!Array.isArray(rows) || rows.length < minimum || rows.some(r => !r.car_number || !r.car_class)) throw new Error('Incomplete fleet roster; retaining previous inventory');
    return this.transaction(() => {
      const groups = new Map();
      for (const raw of rows) {
        const number = String(raw.car_number), equipment = family(raw.car_class);
        const id = `nyct:${equipment}:${number}`;
        const variants = groups.get(id) || []; variants.push(raw); groups.set(id, variants);
        this.db.prepare('INSERT OR IGNORE INTO assertions VALUES(?,?,?)').run(hash(raw), id, JSON.stringify({ ...raw, source, date }));
      }
      for (const [id, variants] of groups) {
        const row = variants.reduce((a, b) => Object.keys(a).length > Object.keys(b).length ? a : b);
        const existing = this.db.prepare('SELECT data FROM cars WHERE id=?').get(id);
        const old = existing ? JSON.parse(existing.data) : {};
        const statuses = [...new Set(variants.map(r => r.retirement_date || 'Unknown'))];
        const facts = {}, conflicts = statuses.length > 1 ? [`Conflicting roster status: ${statuses.join(' / ')}`] : [];
        for (const key of new Set(variants.flatMap(r => Object.keys(r)))) {
          if (['car_number', 'car_class', 'retirement_date'].includes(key)) continue;
          const values = [...new Set(variants.map(r => r[key]).filter(v => v != null && v !== ''))];
          if (values.length > 1) { conflicts.push(`Conflicting ${key}: ${values.join(' / ')}`); facts[key] = 'Conflicting source records'; }
          else if (values.length) facts[key] = String(values[0]);
        }
        const described = String(row.object_description || '').match(/^R\d+[A-Z]?/)?.[0];
        if (described && family(described) !== family(row.car_class)) conflicts.push('Published description and equipment class disagree. Identity is not inferred from the description.');
        const data = { ...old, id, number: String(row.car_number), equipment: family(row.car_class),
          category: old.category || 'passenger', aliases: old.aliases || [],
          lifecycle: statuses.length > 1 ? 'Conflicting roster status' : statuses[0],
          facts,
          evidence: [{ url: source, date, note: 'Published inventory status is not a live service assignment.' }, ...(old.evidence || []).filter(e => e.url !== source)],
          conflicts };
        this.db.prepare('INSERT INTO cars(id,data) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data').run(id, JSON.stringify(data));
      }
      this.meta('roster', { url: source, date, note: 'NYCT inventory; duplicates retained as source assertions, not extra physical cars.' });
      return groups.size;
    });
  }
  importSupplement(supplement) {
    this.transaction(() => {
      for (const car of supplement.cars) {
        if (!car.id || !car.number || !car.evidence?.length) throw new Error('Supplement needs identity and provenance');
        const old = this.db.prepare('SELECT data FROM cars WHERE id=?').get(car.id);
        const previous = old ? JSON.parse(old.data) : {};
        const data = { ...previous, ...car, lifecycle: previous.lifecycle || car.lifecycle,
          evidence: [...new Map([...(previous.evidence || []), ...car.evidence].map(e => [JSON.stringify(e), e])).values()] };
        this.db.prepare('INSERT INTO cars(id,data) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data').run(car.id, JSON.stringify(data));
      }
      this.meta('supplement', supplement.sources);
      this.meta('yardRules', supplement.yardRules || []);
    });
  }
  observe(snapshots, now) {
    const current = new Map();
    this.transaction(() => {
      const claims = new Map();
      for (const s of snapshots) for (const c of s.cars) {
        const key = s.namespace + ':' + c.number;
        claims.set(key, (claims.get(key) || 0) + 1);
      }
      for (const s of snapshots) {
        if (s.observation.timestamp > now + 60 || now - s.observation.timestamp > 300 ||
          s.cars.some(c => claims.get(s.namespace + ':' + c.number) !== 1 || !c.type)) continue;
        const ids = s.cars.map(c => `${s.namespace}:${family(c.type)}:${c.number}`);
        const consistId = 'observed:' + hash([...ids].sort());
        this.db.prepare('INSERT OR IGNORE INTO consists VALUES(?,?)').run(consistId, JSON.stringify(ids));
        for (const id of ids) current.set(id, consistId);
        const observation = { ...s.observation, cars: ids, consistId };
        const signature = hash([consistId, ids, observation.route, observation.location, observation.tripKey]);
        const eventId = hash([signature, observation.timestamp]);
        let changed = false;
        for (let i = 0; i < ids.length; i++) {
          const id = ids[i], car = s.cars[i];
          const row = this.db.prepare('SELECT * FROM cars WHERE id=?').get(id);
          if (row?.last && JSON.parse(row.last).timestamp > observation.timestamp) continue;
          if (!row) {
            const data = { id, number: car.number, equipment: family(car.type), category: s.namespace === 'sir' ? 'sir' : 'passenger',
              aliases: [], lifecycle: 'Observed; roster unverified', evidence: [{ url: 'https://helium-prod.mylirr.org/v1/subway/trips', date: new Date(observation.timestamp * 1000).toISOString(), note: 'Unambiguous live equipment report' }] };
            this.db.prepare('INSERT INTO cars(id,data) VALUES(?,?)').run(id, JSON.stringify(data));
          }
          this.db.prepare('UPDATE cars SET last=?,signature=? WHERE id=?').run(JSON.stringify(observation), signature, id);
          if (row?.signature !== signature) changed = true;
        }
        if (changed) {
          this.db.prepare('INSERT OR IGNORE INTO events VALUES(?,?,?)').run(eventId, observation.timestamp, JSON.stringify(observation));
          for (const id of ids) this.db.prepare('INSERT OR IGNORE INTO event_cars VALUES(?,?)').run(eventId, id);
        }
      }
      this.meta('observedAt', now);
    });
    this.current = current;
  }
  all(now) {
    const yardRules = JSON.parse(this.db.prepare("SELECT data FROM meta WHERE key='yardRules'").get()?.data || '[]');
    const cars = this.db.prepare('SELECT data,last FROM cars').all().map(row => {
      const car = JSON.parse(row.data), last = row.last ? JSON.parse(row.last) : undefined;
      const reporting = !!last && this.current.get(car.id) === last.consistId && now >= last.timestamp - 60 && now - last.timestamp <= 90;
      const candidates = yardRules.filter(r => r.rosterAssignment ? r.equipment?.includes(car.equipment) : last && now - last.timestamp <= 30 * 86400 && r.routes.includes(last.route) && (!r.equipment || r.equipment.includes(car.equipment)));
      const inferred = new Set(candidates.map(r => r.name)).size === 1 ? candidates[0] : undefined;
      return { ...car, last, reporting, estimatedYard: car.yard || (inferred ? { name: inferred.name, url: inferred.url, date: inferred.date, note: `Estimated from ${inferred.rosterAssignment ? `documented ${car.equipment} fleet assignment` : `last observed ${last.route} route`}; not a yard location report. ${inferred.note}` } : undefined) };
    });
    const numbers = new Map();
    for (const car of cars) { const key = car.id.split(':')[0] + ':' + car.number; numbers.set(key, (numbers.get(key) || 0) + 1); }
    for (const car of cars) if (numbers.get(car.id.split(':')[0] + ':' + car.number) > 1) car.conflicts = [...(car.conflicts || []), 'Number reused or conflicting roster identity; equipment identities kept separate.'];
    return cars;
  }
  list(query, now) {
    const cars = this.all(now), groups = new Map();
    for (const car of cars) {
      // Never resurrect a historical formation as a current linked set.
      const group = query.view === 'cars' ? car.id : car.reporting ? car.last.consistId : car.fixedSet || car.id;
      const a = groups.get(group) || []; a.push(car); groups.set(group, a);
    }
    const terms = String(query.q || '').toLowerCase().trim().split(/\s+/).filter(Boolean);
    const rows = [...groups].map(([id, members]) => {
      const order = members.find(c => c.reporting)?.last.cars;
      members.sort((a, b) => order ? order.indexOf(a.id) - order.indexOf(b.id) : a.number.localeCompare(b.number, undefined, { numeric: true }));
      return { id, cars: members, kind: id.startsWith('observed:') || id.startsWith('set:') ? 'consist' : 'car', reporting: members.some(c => c.reporting) };
    }).filter(row => row.cars.some(c =>
      (!query.category || c.category === query.category) && (!query.equipment || c.equipment.toLowerCase().includes(query.equipment.toLowerCase())) &&
      (!query.route || c.last?.route === query.route) && (!query.yard || c.estimatedYard?.name.toLowerCase().includes(query.yard.toLowerCase())) &&
      (query.retired === 'true' || c.reporting || !/retired|scrapped|^\d{2}\/\d{2}\/\d{4}$/.test(c.lifecycle.toLowerCase())) &&
      (query.status !== 'reporting' || c.reporting) && (query.status !== 'unreported' || !c.reporting) &&
      terms.every(t => `${c.number} ${c.aliases.join(' ')} ${c.equipment} ${c.last?.location || ''} ${c.estimatedYard?.name || ''}`.toLowerCase().includes(t))))
      .sort((a, b) => Number(b.reporting) - Number(a.reporting) || a.cars[0].number.localeCompare(b.cars[0].number, undefined, { numeric: true }) || a.id.localeCompare(b.id));
    const pages = Math.max(1, Math.ceil(rows.length / 100));
    const page = Math.min(pages, Math.max(1, Number(query.page) || 1));
    return { rows: rows.slice((page - 1) * 100, page * 100), page, pages, total: rows.length, generatedAt: now,
      coverage: ['passenger', 'sir', 'work', 'museum'].map(category => ({ category, count: cars.filter(c => c.category === category).length,
        note: category === 'passenger' ? 'Published NYCT roster plus observed cars; roster status may conflict.' : 'Partial documented inventory; live reporting is not guaranteed.' })),
      sources: [JSON.parse(this.db.prepare("SELECT data FROM meta WHERE key='roster'").get()?.data || 'null'), ...JSON.parse(this.db.prepare("SELECT data FROM meta WHERE key='supplement'").get()?.data || '[]')].filter(Boolean) };
  }
  detail(id, now) {
    const members = JSON.parse(this.db.prepare('SELECT data FROM consists WHERE id=?').get(id)?.data || '[]');
    const cars = this.all(now).filter(c => c.id === id || c.fixedSet === id || members.includes(c.id));
    if (members.length) {
      const order = cars.find(c => c.reporting && c.last?.consistId === id)?.last.cars || members;
      cars.sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id));
    }
    if (!cars.length) return undefined;
    const ids = cars.map(c => c.id), params = ids.map(() => '?').join(',');
    const history = this.db.prepare(`SELECT DISTINCT e.id,e.data,e.timestamp FROM events e JOIN event_cars ec ON ec.event_id=e.id WHERE ec.car_id IN (${params}) AND e.timestamp>=? ${members.length ? "AND json_extract(e.data, '$.consistId')=?" : ''} ORDER BY e.timestamp DESC LIMIT 200`).all(...ids, now - 30 * 86400, ...(members.length ? [id] : [])).map(r => JSON.parse(r.data));
    return { cars, history, generatedAt: now };
  }
  cleanup(now) { this.db.prepare('DELETE FROM events WHERE timestamp<?').run(now - 30 * 86400); }
  backup(destination) { this.db.prepare('VACUUM INTO ?').run(destination); }
  close() { this.db.close(); }
}
