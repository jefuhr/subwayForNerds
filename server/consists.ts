import type { Consist, Train } from '../shared/types';
import { CONSIST_MAX_AGE, currentConsist } from '../shared/consist';

export const HELIUM_URL = 'https://helium-prod.mylirr.org/v1/subway/trips';
export interface ConsistTrip { route: string; consist: Consist }

export function normalizeConsists(raw: any, fetchedAt: number): Map<string, ConsistTrip> {
  if (!raw || !Array.isArray(raw.trips)) throw new Error('Unexpected Helium trips response');
  const trips = new Map<string, ConsistTrip>(), seen = new Set<string>();
  const staleRoutes = new Set(Array.isArray(raw.staleRouteIds) ? raw.staleRouteIds : []);
  for (const trip of raw.trips) {
    if (!trip || typeof trip.tripId !== 'string' || !trip.tripId) continue;
    // Ambiguous operations IDs must not pick an arbitrary physical train.
    if (seen.has(trip.tripId)) { trips.delete(trip.tripId); continue; }
    seen.add(trip.tripId);
    if (typeof trip.routeId !== 'string' || staleRoutes.has(trip.routeId) || trip.isAssigned === false ||
        typeof trip.updatedAt !== 'number' || !Number.isFinite(trip.updatedAt) ||
        !Array.isArray(trip.consistCars) || !trip.consistCars.length || trip.consistCars.length > 20) continue;
    if (!trip.consistCars.every((car: any) => car && typeof car.number === 'string' && /^\d{1,6}$/.test(car.number))) continue;
    if (new Set(trip.consistCars.map((car: any) => car.number)).size !== trip.consistCars.length) continue;
    const consist: Consist = {
      cars: trip.consistCars.map((car: any) => ({ number: car.number, ...(typeof car.type === 'string' && car.type ? { type: car.type } : {}) })),
      updatedAt: trip.updatedAt, fetchedAt, source: 'helium',
    };
    if (currentConsist(consist, fetchedAt)) trips.set(trip.tripId, { route: trip.routeId, consist });
  }
  return trips;
}

export function enrichConsist(train: Train, trips: Map<string, ConsistTrip>, now: number) {
  delete train.consist;
  const match = train.trainId ? trips.get(train.trainId) : undefined;
  if (!match || train.assigned === false || train.route !== match.route ||
      Math.abs(train.timestamp - match.consist.updatedAt) > CONSIST_MAX_AGE || !currentConsist(match.consist, now)) return;
  train.consist = match.consist;
}
