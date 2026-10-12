import { probeNjt } from '../server/njt-probe';

const report = await probeNjt({ credentials: {
	username: process.env.NJT_USERNAME ?? '',
	password: process.env.NJT_PASSWORD ?? '',
} });
process.stdout.write(JSON.stringify(report, null, 2) + '\n');
// A populated response is evidence for review, never proof of realtime coverage.
if (report.access !== 'authenticated' || report.samples.some(s => s.departures.status === 'failed' || s.positions.status === 'failed')) process.exitCode = 1;
