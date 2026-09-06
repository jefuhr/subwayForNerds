import type { DatabaseSync } from 'node:sqlite';
import type { FleetCar, FleetDetail, FleetPage, FleetSnapshot } from '../shared/fleet';
export class FleetStore {
  constructor(file: string);
  db: DatabaseSync;
  importRoster(rows: unknown, date: string, minimum?: number): number;
  importSupplement(supplement: { cars: FleetCar[]; sources: unknown[]; yardRules?: unknown[] }): void;
  observe(snapshots: FleetSnapshot[], now: number): void;
  list(query: Record<string, string>, now: number): FleetPage;
  detail(id: string, now: number): FleetDetail | undefined;
  all(now: number): FleetCar[];
  cleanup(now: number): void;
  backup(destination: string): void;
  close(): void;
}
