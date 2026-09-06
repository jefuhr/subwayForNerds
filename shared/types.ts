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
  id: string; name: string; stationId?: string; arrival: number | null; departure: number | null;
  scheduledTrack?: string; actualTrack?: string; relationship?: string;
}
export interface Train {
  key: string; feed: string; tripId: string; serviceDate?: string; route: string;
  destination: string; direction: string; trainId?: string; assigned?: boolean;
  timestamp: number; position?: { stopId?: string; name: string; status?: string; timestamp?: number };
  stops: StopPrediction[]; relationship?: string; alerts: string[];
  scheduledPattern?: { shape: string; headsign: string; stops: string[]; source: string };
}
export interface Departure {
  key: string; tripKey: string; route: string; destination: string; direction: string;
  stopId: string; partId: string; area: string; time: number | null; arrival: number | null;
  scheduledTrack?: string; actualTrack?: string; pattern: string; patternSource: 'inferred' | 'static';
  location: string; locationTimestamp?: number; stopsAway: number | null;
  assigned?: boolean; feed: string; timestamp: number; relationship?: string; alerts: string[];
  onward: { stationId: string; stopId: string; name: string; time: number | null }[];
}
export interface ServiceAlert {
  id: string; title: string; description: string; effect?: string;
  routes: string[]; stops: string[]; selectors: { route?: string; stop?: string; trip?: string; direction?: number }[];
  periods: { start?: number; end?: number }[]; updatedAt?: number; raw?: unknown;
}
export interface Board {
  station: Station; generatedAt: number; sources: SourceState[];
  departures: Departure[]; alerts: ServiceAlert[];
}
export interface StationContext {
  entrances: Record<string, string>[]; equipment: Record<string, string>[];
  outages: Record<string, string>[]; sources: SourceState[];
}
