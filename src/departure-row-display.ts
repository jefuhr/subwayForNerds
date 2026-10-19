/** Board positions can omit any part without leaving empty separators. */
export function combinedPosition(location: string | undefined, stopsAway: string, age: string, historical: boolean): string {
	if (!location) return [stopsAway || 'Stop-relative position', age].filter(Boolean).join(' · ');
	return [`${historical ? 'Last report: ' : ''}${location}`, stopsAway, age].filter(Boolean).join(' · ');
}
