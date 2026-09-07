export type FleetCategory = 'passenger' | 'work' | 'museum' | 'sir';
export interface Evidence { url: string; date: string; note: string }
export interface FleetObservation {
  timestamp: number; locationTimestamp?: number; location: string; route: string; tripKey: string;
  consistId: string; cars: string[]; next?: { stationId?: string; name: string; time: number | null };
}
export interface FleetCar {
  id: string; number: string; equipment: string; category: FleetCategory; aliases: string[];
  lifecycle: string; evidence: Evidence[]; conflicts?: string[]; fixedSet?: string;
  facts?: Record<string, string>;
  yard?: Evidence & { name: string }; last?: FleetObservation;
  reporting?: boolean; estimatedYard?: Evidence & { name: string };
}
export interface FleetRow { id: string; kind: 'car' | 'consist'; cars: FleetCar[]; reporting: boolean }
export interface FleetPage {
  rows: FleetRow[]; total: number; page: number; pages: number; generatedAt: number;
  coverage: { category: string; count: number; note: string }[];
  facets: { equipment: string[]; route: string[]; yard: string[] };
  sources: Evidence[]; error?: string;
}
export interface FleetDetail { cars: FleetCar[]; history: FleetObservation[]; generatedAt: number }
export interface FleetSnapshot {
  cars: { number: string; type?: string }[]; namespace: string;
  observation: Omit<FleetObservation, 'consistId' | 'cars'>;
}
