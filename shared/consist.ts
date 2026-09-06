import type { Consist } from './types';

export const CONSIST_MAX_AGE = 300;
export function currentConsist(consist: Consist | undefined, now: number): consist is Consist {
  return !!consist && [consist.updatedAt, consist.fetchedAt].every(time => time > 0 && now - time <= CONSIST_MAX_AGE && time <= now + 60);
}

// Preserve reported order and split ranges when numbering changes direction.
export function consistSummary(cars: Consist['cars']): string {
  const ranges: string[] = [];
  for (let start = 0; start < cars.length;) {
    let end = start;
    const step = Number(cars[start + 1]?.number) - Number(cars[start].number);
    if (Math.abs(step) === 1) {
      while (end + 1 < cars.length && Number(cars[end + 1].number) - Number(cars[end].number) === step) end++;
    }
    ranges.push(end === start ? cars[start].number : `${cars[start].number}–${cars[end].number}`);
    start = end + 1;
  }
  return ranges.join(', ');
}
