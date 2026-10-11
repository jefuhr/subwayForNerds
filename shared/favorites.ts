import { currentConsist } from './consist';
import { validFleetCarID, type TrainFavorites } from './settings';
import type { Consist } from './types';

/** Match fleet identities, never trip IDs or an unqualified car number. */
export function fleetCarID(number: string, type: string | undefined, feed: string): string | undefined {
	if (!type) return;
	const family = /^R160[AB]?$/.test(type) ? 'R160' : type;
	const id = `${feed === 'gtfs-si' ? 'sir' : 'nyct'}:${family}:${number}`;
	return validFleetCarID(id) ? id : undefined;
}
export function consistCarIDs(consist: Consist | undefined, feed: string): string[] | undefined {
	if (!consist?.cars.length || consist.cars.length > 20) return;
	const ids = consist.cars.map(car => fleetCarID(car.number, car.type, feed));
	if (ids.some(id => id === undefined) || new Set(ids).size !== ids.length) return;
	return (ids as string[]).sort();
}
export const consistKey = (ids: readonly string[]) => JSON.stringify([...ids].sort());

export function favoriteTrainMatch(consist: Consist | undefined, feed: string, favorites: TrainFavorites, now: number, cached = false): { carIDs: string[]; exactConsist: boolean } | null {
	if (cached || !currentConsist(consist, now)) return null;
	const ids = consistCarIDs(consist, feed);
	if (!ids) return null;
	const exactConsist = favorites.consists.some(saved => consistKey(saved) === consistKey(ids));
	const savedCars = new Set([...favorites.cars, ...(favorites.match === 'anyCar' ? favorites.consists.flat() : [])]);
	const carIDs = exactConsist ? ids : ids.filter(id => savedCars.has(id));
	return carIDs.length ? { carIDs, exactConsist } : null;
}
