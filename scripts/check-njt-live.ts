import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { TransitService } from '../server/service';

const cacheDir = path.resolve('artifacts/njt-live-state');
await mkdir(cacheDir, { recursive: true });
const service = new TransitService({ cacheDir });
if (!service.njt.enabled) {
	process.stdout.write(JSON.stringify({ configured: false, error: 'NJT credentials missing or integration disabled' }, null, 2) + '\n');
	process.exitCode = 1;
} else {
	try {
		await service.njt.restore();
		await service.njt.refreshStatic();
		await service.njt.refreshPredictions();
		await service.njt.refreshPositions();
		service.refreshBoards();
		const restored = new TransitService({ cacheDir });
		await restored.njt.restore();
		restored.refreshBoards();
		const stations = ['njt-lr-30829', 'njt-lr-30771', 'njt-lr-30855'].map(id => {
			const board = service.boards.get(id)!;
			const cached = restored.boards.get(id)!;
			return {
				id, name: board.station.name, predictions: board.departures.length,
				positions: board.vehiclePositions?.length ?? 0,
				positionRestoreMatches: JSON.stringify(board.vehiclePositions) === JSON.stringify(cached.vehiclePositions),
				sources: board.sources,
			};
		});
		const report = { checkedAt: new Date().toISOString(), health: service.njt.health(), stations };
		await writeFile('artifacts/njt-live-acceptance.json', JSON.stringify(report, null, 2) + '\n');
		process.stdout.write(JSON.stringify(report, null, 2) + '\n');
		if (stations.some(station => !station.positionRestoreMatches) || report.health.cacheError) process.exitCode = 1;
	} catch {
		// Upstream bodies and thrown diagnostics can contain credentials; omit them.
		process.stdout.write(JSON.stringify({ configured: true, error: 'NJT live acceptance check failed', health: service.njt.health() }, null, 2) + '\n');
		process.exitCode = 1;
	}
}
await service.stop();
