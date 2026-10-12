/** Read-only coverage research. Results never enable production capabilities. */
const base = 'https://pcsdata.njtransit.com/api/BUSDV2/';
const samples = [
	{ mode: 'HBLR', stop: '30829', lat: '40.735', lon: '-74.029' },
	{ mode: 'NLR', stop: '30771', lat: '40.735', lon: '-74.164' },
	{ mode: 'RL', stop: '30855', lat: '40.218', lon: '-74.755' },
];
type Evidence = { status: 'empty' | 'unverified' | 'failed'; count?: number; fields?: string[]; httpStatus?: number };
type Credentials = { username: string; password: string };
type Options = { credentials?: Credentials; fetcher?: typeof fetch };
const allowedFields = new Set([
	'public_route', 'header', 'departuretime', 'remarks', 'internal_trip_number',
	'sched_dep_time', 'timing_point_id', 'vehicle_id', 'VehicleLat', 'VehicleLong',
	'VehicleID', 'VehicleRoute', 'VehicleDestination', 'VehicleInternalTripNumber',
	'VehicleScheduledDeparture',
]);

export async function probeNjt({ credentials, fetcher = fetch }: Options = {}) {
	const report = {
		checkedAt: new Date().toISOString(), provider: 'BUSDV2', environment: 'production',
		integrationReady: false,
		access: 'missing-credentials' as 'missing-credentials' | 'failed' | 'authenticated',
		scope: 'One station and a one-mile vehicle search per system; empty responses are inconclusive.',
		samples: [] as { mode: string; stop: string; fetchedAt: string; departures: Evidence; positions: Evidence }[],
	};
	if (!credentials?.username || !credentials.password) return report;
	async function post(method: string, fields: Record<string, string>) {
		const body = new FormData();
		for (const [key, value] of Object.entries(fields)) body.set(key, value);
		const response = await fetcher(base + method, {
			method: 'POST', body, signal: AbortSignal.timeout(12_000), redirect: 'error',
		});
		// Never propagate upstream error text, URLs, credentials, or arbitrary payloads.
		if (!response.ok) return { httpStatus: response.status, data: null };
		return { httpStatus: response.status, data: await response.json() };
	}
	let token: string;
	try {
		const { data } = await post('authenticateUser', credentials);
		if (data?.Authenticated !== 'True' || typeof data.UserToken !== 'string' || !data.UserToken.trim()) {
			report.access = 'failed';
			return report;
		}
		token = data.UserToken;
	} catch {
		report.access = 'failed';
		return report;
	}
	report.access = 'authenticated';
	async function evidence(method: string, fields: Record<string, string>, wrapper?: string): Promise<Evidence> {
		try {
			const { httpStatus, data } = await post(method, { token, ...fields });
			const rows: unknown = wrapper ? data?.[wrapper] : data;
			if (!Array.isArray(rows) || rows.some(row => !row || typeof row !== 'object' || Array.isArray(row))) return { status: 'failed', httpStatus };
			return {
				status: rows.length ? 'unverified' : 'empty', count: rows.length, httpStatus,
				fields: [...new Set(rows.flatMap(row => Object.keys(row).filter(key => allowedFields.has(key))))].sort(),
			};
		} catch { return { status: 'failed' }; }
	}
	for (const { mode, stop, lat, lon } of samples) {
		const departures = await evidence('getBusDV', { stop, route: '', direction: '', IP: '' }, 'DVTrip');
		const positions = await evidence('getVehicleLocations', { mode, lat, lon, radius: '1' });
		report.samples.push({ mode, stop, fetchedAt: new Date().toISOString(), departures, positions });
	}
	return report;
}
