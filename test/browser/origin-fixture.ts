import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';

export async function unusedLoopbackPort(): Promise<number> {
	const reservation = createServer();
	await new Promise<void>((resolve, reject) => {
		reservation.once('error', reject);
		reservation.listen(0, '127.0.0.1', resolve);
	});
	const address = reservation.address();
	if (!address || typeof address === 'string') throw new Error('Could not reserve a fixture port');
	await new Promise<void>((resolve, reject) => reservation.close(error => error ? reject(error) : resolve()));
	return address.port;
}

/** A separate origin lets WebKit test real server loss without Playwright's offline-emulation bug. */
export async function startOriginFixture(port: number) {
	const child = spawn(process.execPath, ['--import', 'tsx', 'test/fixture-server.ts'], {
		env: { ...process.env, FIXTURE_PORT: String(port) }, stdio: ['ignore', 'pipe', 'pipe'],
	});
	let output = '', spawnError: Error | undefined;
	const record = (chunk: Buffer) => { output = (output + chunk.toString()).slice(-32768); };
	child.stdout.on('data', record); child.stderr.on('data', record);
	child.once('error', error => { spawnError = error; });
	const exited = new Promise<void>(resolve => { child.once('exit', () => resolve()); child.once('error', () => resolve()); });
	const stop = async () => {
		if (child.exitCode != null || child.signalCode != null || spawnError) return;
		child.kill('SIGTERM');
		const stopped = await Promise.race([exited.then(() => true), delay(5000).then(() => false)]);
		if (!stopped) { child.kill('SIGKILL'); await exited; }
	};
	const origin = `http://127.0.0.1:${port}`;
	try {
		const deadline = Date.now() + 60000;
		while (Date.now() < deadline) {
			if (spawnError || child.exitCode != null || child.signalCode != null) throw new Error(`Fixture process exited: ${spawnError?.message || output}`);
			try {
				const response = await fetch(origin + '/healthz', { signal: AbortSignal.timeout(1000) });
				if (response.ok) return { origin, stop, output: () => output };
			} catch { /* The recorded database is still being prepared. */ }
			await delay(100);
		}
		throw new Error(`Isolated fixture startup timed out: ${output}`);
	} catch (error) { await stop(); throw error; }
}
