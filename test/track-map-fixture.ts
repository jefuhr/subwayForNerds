import type { FastifyInstance } from 'fastify';

/** Opt-in controls for local native acceptance. Never installed by the production server. */
export function installTrackMapFixtureControls(app: FastifyInstance) {
	let requests = 0;
	let unavailable = false;
	const state = () => ({ requests, unavailable });
	app.addHook('onRequest', async (request, reply) => {
		const path = request.url.split('?')[0];
		if (request.method !== 'GET' || !/\/api\/v1\/track-map\/[^/]+\/snapshot$/.test(path)) return;
		requests++;
		if (unavailable) return reply.code(503).send({ error: 'Synthetic track map outage for native acceptance' });
	});
	app.get('/__test/track-map', state);
	app.put<{ Body: { unavailable?: boolean; resetRequests?: boolean } }>('/__test/track-map', (request, reply) => {
		const body = request.body;
		if (!body || typeof body !== 'object' || Array.isArray(body)
			|| (body.unavailable !== undefined && typeof body.unavailable !== 'boolean')
			|| (body.resetRequests !== undefined && typeof body.resetRequests !== 'boolean')
			|| Object.keys(body).some(key => key !== 'unavailable' && key !== 'resetRequests')) {
			return reply.code(400).send({ error: 'Expected unavailable and resetRequests booleans' });
		}
		if (body.unavailable !== undefined) unavailable = body.unavailable;
		if (body.resetRequests) requests = 0;
		return state();
	});
}
