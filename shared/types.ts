export interface StationPart {
  id: string; stationId: string; name: string; line: string; routes: string[];
  lat: number; lon: number; ada: string; adaNotes: string; north: string; south: string;
}
export interface Station {
  id: string; name: string; borough: string; routes: string[]; lat: number; lon: number; parts: StationPart[];
}
export interface SourceState {
  id: string; timestamp: number | null; fetchedAt: number | null; error: string | null;
}
export interface StopPrediction {
  changes?: TripChange[];
  sequence?: number;
  id: string; name: string; stationId?: string; arrival: number | null; departure: number | null;
  scheduledTrack?: string; actualTrack?: string; relationship?: string;
}
export interface TransferResult {
  originTimestamp?: number;
  station?: Station; arrival: number | null; basis: 'arrival' | 'departure'; message?: string;
  connections: (Departure & { gap: number; basis: 'arrival' | 'departure' })[]; sources: SourceState[];
}
export interface Consist {
  cars: { number: string; type?: string }[];
  updatedAt: number; fetchedAt: number; source: 'helium';
}
export interface Train {
  changes?: TripChange[];
  startTime?: string;
  key: string; feed: string; tripId: string; serviceDate?: string; route: string;
  destination: string; direction: string; trainId?: string; assigned?: boolean;
  timestamp: number; position?: { stopId?: string; name: string; status?: string; timestamp?: number };
  stops: StopPrediction[]; relationship?: string; alerts: string[];
  consist?: Consist;
  scheduledPattern?: { shape: string; headsign: string; stops: string[]; source: string };
}
export interface Departure {
  changes?: TripChange[];
  departure?: number | null;
  key: string; tripKey: string; route: string; destination: string; direction: string;
  stopId: string; partId: string; area: string; time: number | null; arrival: number | null;
  scheduledTrack?: string; actualTrack?: string; pattern: string; patternSource: 'inferred' | 'static';
  location: string; locationTimestamp?: number; stopsAway: number | null;
  assigned?: boolean; feed: string; timestamp: number; relationship?: string; alerts: string[];
  consist?: Consist;
  onward: { stationId: string; stopId: string; name: string; time: number | null }[];
}
export interface ServiceAlert {
  alertType?: string; activePeriodLabel?: string; planNumbers?: string[];
  affectedSelectors?: AlertSelector[];
  id: string; title: string; description: string; effect?: string;
  routes: string[]; stops: string[]; selectors: AlertSelector[];
  periods: { start?: number; end?: number }[]; updatedAt?: number; raw?: unknown;
}
export interface AlertSelector {
  route?: string; stop?: string; trip?: string; direction?: number;
  serviceDate?: string; startTime?: string; priority?: number;
}
export interface TripChange {
  id: string;
  kind: 'track' | 'boarding' | 'pattern' | 'skip' | 'cancellation' | 'advisory';
  classification: 'scheduled' | 'planned' | 'unplanned' | 'unknown';
  label: string; description?: string; location?: string;
  // Indices address occurrences in this snapshot, not persistent stop identities.
  stopIndices: number[]; affectedStops: string[];
  before?: string; after?: string;
  evidence: { source: string; timestamp: number; staleAfter: number; unavailable?: boolean }[];
  alertIds: string[];
  advisory?: boolean;
}
export interface Board {
  station: Station; generatedAt: number; sources: SourceState[];
  departures: Departure[]; alerts: ServiceAlert[];
}
export interface StationContext {
  entrances: Record<string, string>[]; equipment: Record<string, string>[];
  outages: Record<string, string>[]; sources: SourceState[];
}
