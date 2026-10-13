export interface FleetOfflineManifest {
  schemaVersion: 1;
  id: string;
  generatedAt: number;
  historyStart: number;
  historyEnd: number;
  observedAt?: number;
  counts: { cars: number; consists: number; events: number; assertions: number };
  byteLength: number;
  sha256: string;
  /** Identity above always describes the uncompressed SQLite database. */
  compression?: 'gzip';
  compressedByteLength?: number;
  compressedSha256?: string;
  /** Origin-relative URL under the configured application prefix. */
  downloadURL: string;
}

export interface FleetPackSelection {
  equipment: string[];
  yards: string[];
  historyDays: 7 | 30;
}

export interface FleetPackManifest {
  schemaVersion: 2;
  format: 'fleet-jsonl-v2';
  compression: 'gzip';
  id: string;
  generatedAt: number;
  historyStart: number;
  historyEnd: number;
  observedAt?: number;
  selection: FleetPackSelection;
  counts: { cars: number; consists: number; events: number; assertions: number; eventCars: number; matchedCars: number; linkedCars: number };
  archiveByteLength: number;
  archiveSha256: string;
  uncompressedByteLength: number;
  estimatedSavedByteLength: number;
  downloadURL: string;
}

/** Build progress of a preparing pack. Counts are exact within a stage; `fraction` covers the whole build. */
export interface FleetPackProgress {
  stage: string;
  label: string;
  step: number;
  steps: number;
  done: number;
  total: number;
  fraction: number;
}
