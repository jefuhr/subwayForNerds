import type { SourceState } from './types';

/** Coordinates are PDF points, with the origin at the top left of the crop box. */
export interface TrackMapPoint { x: number; y: number }
export interface TrackMapStation {
	id: string;
	stationId: string;
	partId: string;
	name: string;
	point: TrackMapPoint;
	stopIds: string[];
}
export interface TrackMapNode { id: string; point: TrackMapPoint }
export interface TrackMapEdge {
	id: string;
	from: string;
	to: string;
	points: TrackMapPoint[];
	bidirectional: boolean;
	revenue: boolean;
}
export interface TrackMapPlatform {
	id: string;
	stopId: string;
	trackCodes: string[];
	nodeId: string;
}
export interface TrackMapTopology {
	schemaVersion: 1;
	mapVersion: string;
	pdfSha256: string;
	page: { width: number; height: number };
	attribution: string;
	sourceURL: string;
	stations: TrackMapStation[];
	nodes: TrackMapNode[];
	edges: TrackMapEdge[];
	platforms: TrackMapPlatform[];
	coverage: { mappedStopIds: string[]; unresolvedStopIds: string[]; notes: string[] };
}

/** Progress is arc length along points, from 0 to 1, clamped to this window. */
export interface TrackMapMotion {
	edgeIds: string[];
	points: TrackMapPoint[];
	fromProgress: number;
	toProgress: number;
	startTime: number;
	endTime: number;
}
export interface TrackMapTrain {
	key: string;
	feed: string;
	route: string;
	destination: string;
	direction: string;
	stopId?: string;
	stationId?: string;
	status?: string;
	trackCode?: string;
	trackBasis: 'reported' | 'scheduled' | 'inferred' | 'unknown';
	positionBasis: 'reported' | 'estimated' | 'unknown';
	placement: 'track' | 'near-stop' | 'unplaced';
	point?: TrackMapPoint;
	motion?: TrackMapMotion;
	/** Original evidence age, never the time a cached response was read. */
	observedAt: number | null;
	feedTimestamp: number;
	staleAt: number | null;
	expiresAt: number | null;
	freshness: 'live' | 'stale' | 'unavailable';
	reason?: string;
}
export interface TrackMapSnapshot {
	schemaVersion: 1;
	mapVersion: string;
	pdfSha256: string;
	generatedAt: number;
	sources: SourceState[];
	trains: TrackMapTrain[];
	coverage: { placed: number; uncertain: number; unplaced: number };
}
