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
