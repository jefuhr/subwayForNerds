import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import Fastify from 'fastify';
import { AccountStore, type Challenge } from '../server/account-store';
import { registerAccounts, type AccountOptions } from '../server/accounts';

const callback = 'nyc.juliet.subwaysfornerds://auth/android';
const verifier = 'a'.repeat(64);
const codeChallenge = createHash('sha256').update(verifier).digest('base64url');
const state = 's'.repeat(43);
async function fixture() {
	let time = Math.floor(Date.now() / 1000);
	let hold: (() => Promise<void>) | undefined;
	const store = new AccountStore(':memory:', Buffer.alloc(32, 7), () => time);
	const app = Fastify();
	const verified: Challenge[] = [];
	const options: AccountOptions = { store, origin: 'https://example.test', providers: {
		apple: { nativeClientID: 'apple-app', webClientID: 'apple-web', authorize: (c, id, redirect) => 'https://apple.example/authorize?' + new URLSearchParams({ state: id, nonce: c.nonce, redirect_uri: redirect }), verify: async (c, input) => {
			verified.push(c);
			await hold?.();
			if (input.code !== 'valid-' + c.nonce) throw new Error('Forged callback');
			return { provider: 'apple', subject: 'apple-one', clientID: c.platform === 'native' ? 'apple-app' : 'apple-web', grant: 'private-provider-grant' };
		}, revoke: async () => {} },
		google: { nativeClientID: 'google-ios', webClientID: 'google-web', authorize: (c, id, redirect) => 'https://google.example/authorize?' + new URLSearchParams({ state: id, nonce: c.nonce, redirect_uri: redirect }), verify: async (c, input) => {
			await hold?.();
			if (input.code !== 'valid-' + c.nonce) throw new Error('Forged callback');
			return { provider: 'google', subject: 'google-one', clientID: 'google-web', grant: 'private-google-grant' };
		}, revoke: async () => {} },
	} };
	await registerAccounts(app, '/api/v1', options, { exemptLoopback: true });
	const start = async (intent = 'login', token?: string, provider = 'apple') => {
		const result = await app.inject({ method: 'POST', url: '/api/v1/auth/challenges', headers: token ? { authorization: 'Bearer ' + token } : {}, payload: { provider, platform: 'android', intent, codeChallenge, codeChallengeMethod: 'S256', state } });
		assert.equal(result.statusCode, 200, result.body);
		const challenge = result.json();
		assert.equal(new URL(challenge.authorizationURL).origin, 'https://example.test');
		const binding = await app.inject({ url: new URL(challenge.authorizationURL).pathname + new URL(challenge.authorizationURL).search });
		assert.equal(binding.statusCode, 303, binding.body);
		const cookie = binding.cookies.find(c => c.name === 'sfn_oauth')!;
		assert.ok(cookie);
		return { ...challenge, provider, cookie: cookie.name + '=' + cookie.value };
	};
	const finish = (c: any, error?: string) => app.inject({ method: 'POST', url: '/api/v1/auth/' + c.provider + '/callback', headers: { cookie: c.cookie }, payload: { state: c.id, ...(error ? { error } : { code: 'valid-' + c.nonce }) } });
	const exchange = (location: string, token?: string, proof = verifier) => {
		const url = new URL(location);
		return app.inject({ method: 'POST', url: '/api/v1/auth/android/exchange', headers: token ? { authorization: 'Bearer ' + token } : {}, payload: { handoff: url.searchParams.get('handoff'), state: url.searchParams.get('state'), verifier: proof } });
	};
	return { app, store, verified, start, finish, exchange, advance: (seconds: number) => { time += seconds; }, hold: (value: () => Promise<void>) => { hold = value; } };
}

test('Android account routes remain absent when public auth is disabled', async () => {
	const app = Fastify(); await registerAccounts(app, '/api/v1');
	try {
		assert.deepEqual((await app.inject('/api/v1/auth/config')).json(), { enabled: false });
		for (const url of ['/api/v1/auth/challenges', '/api/v1/auth/android/exchange']) assert.equal((await app.inject({ method: 'POST', url, payload: {} })).statusCode, 404);
	} finally { await app.close(); }
});
test('Android starts require S256 app PKCE and reject callback destinations', async () => {
	const f = await fixture();
	try {
		for (const override of [{ codeChallenge: '' }, { codeChallenge: 'x' }, { codeChallengeMethod: 'plain' }, { state: '' }, { callback: 'evil://auth' }, { redirectURI: 'https://evil.test' }]) {
			const response = await f.app.inject({ method: 'POST', url: '/api/v1/auth/challenges', payload: { provider: 'apple', platform: 'android', intent: 'login', codeChallenge, codeChallengeMethod: 'S256', state, ...override } });
			assert.equal(response.statusCode, 400, response.body);
		}
	} finally { await f.app.close(); }
});
test('Android browser callback emits only a bound opaque handoff and exchange creates one session', async () => {
	const f = await fixture();
	try {
		const c = await f.start();
		const response = await f.finish(c);
		assert.equal(response.statusCode, 303, response.body);
		const url = new URL(response.headers.location!);
		assert.equal(url.origin + url.pathname, new URL(callback).origin + new URL(callback).pathname);
		assert.equal(url.protocol, 'nyc.juliet.subwaysfornerds:'); assert.equal(url.hostname, 'auth'); assert.equal(url.pathname, '/android');
		assert.equal(url.searchParams.get('state'), state);
		assert.deepEqual([...url.searchParams.keys()].sort(), ['handoff', 'state']);
		assert.ok(url.searchParams.get('handoff'));
		assert.equal(response.cookies.some(c => c.name === '__Secure-sfn_session'), false);
		assert.equal(f.verified[0].platform, 'android');
		const login = await f.exchange(response.headers.location!);
		assert.equal(login.statusCode, 200, login.body); assert.ok(login.json().token);
		assert.equal(response.headers.location!.includes(login.json().token), false);
		assert.equal(response.headers.location!.includes('private-provider-grant'), false);
		assert.equal((await f.exchange(response.headers.location!)).statusCode, 401);
		assert.equal((await f.app.inject({ url: '/api/v1/account', headers: { authorization: 'Bearer ' + login.json().token } })).statusCode, 200);
	} finally { await f.app.close(); }
});
test('Android challenge binding rejects forged browsers and callback replay', async () => {
	const f = await fixture();
	try {
		const c = await f.start();
		const forged = await f.app.inject({ method: 'POST', url: '/api/v1/auth/apple/callback', headers: { cookie: 'sfn_oauth=attacker' }, payload: { state: c.id, code: 'valid-' + c.nonce } });
		assert.equal(forged.statusCode, 401); assert.equal(f.verified.length, 0);
		assert.equal((await f.finish(c)).statusCode, 401);
		const next = await f.start();
		assert.equal((await f.finish(next)).statusCode, 303);
		assert.equal((await f.finish(next)).statusCode, 401);
	} finally { await f.app.close(); }
});
test('Android handoff rejects wrong app verifier and state, and failed proofs are single use', async () => {
	const f = await fixture();
	try {
		const c = await f.start(); const done = await f.finish(c);
		assert.equal((await f.exchange(done.headers.location!, undefined, 'b'.repeat(64))).statusCode, 401);
		assert.equal((await f.exchange(done.headers.location!)).statusCode, 401);
		const other = await f.start(); const d = await f.finish(other); const url = new URL(d.headers.location!); url.searchParams.set('state', 'x'.repeat(43));
		assert.equal((await f.exchange(url.toString())).statusCode, 401);
		assert.equal((await f.exchange(d.headers.location!)).statusCode, 401);
	} finally { await f.app.close(); }
});
test('Android cancel/expiry consumes the challenge and never creates a reusable handoff', async () => {
	const f = await fixture();
	try {
		const cancelled = await f.start(); const response = await f.finish(cancelled, 'access_denied');
		assert.equal(response.statusCode, 303); const url = new URL(response.headers.location!);
		assert.equal(url.searchParams.get('error'), 'cancelled'); assert.equal(url.searchParams.get('state'), state); assert.equal(url.searchParams.has('handoff'), false);
		assert.equal((await f.finish(cancelled)).statusCode, 401);
		const expired = await f.start(); f.advance(301); assert.equal((await f.finish(expired)).statusCode, 401);
		const c = await f.start(); const done = await f.finish(c); f.advance(91); assert.equal((await f.exchange(done.headers.location!)).statusCode, 401);
	} finally { await f.app.close(); }
});
test('Android link and reauth require the original live session both at finish and exchange', async () => {
	for (const intent of ['link', 'reauth']) {
		for (const phase of ['finish', 'exchange']) {
			const f = await fixture();
			try {
				const login = await f.exchange((await f.finish(await f.start())).headers.location!); const token = login.json().token;
				const c = await f.start(intent, token);
				const done = phase === 'exchange' ? await f.finish(c) : undefined;
				f.store.logout(token);
				if (phase === 'finish') {
					const finish = await f.finish(c); assert.equal(finish.statusCode, 303); assert.equal(new URL(finish.headers.location!).searchParams.has('handoff'), false);
				} else assert.equal((await f.exchange(done!.headers.location!, token)).statusCode, 401);
				assert.equal(f.store.session(token), null);
			} finally { await f.app.close(); }
		}
	}
});
test('revocation during async provider verification cannot link or reauthenticate Android or native sessions', async () => {
	for (const platform of ['android', 'native']) {
		const f = await fixture();
		try {
			const login = await f.exchange((await f.finish(await f.start())).headers.location!); const token = login.json().token;
			let release!: () => void; let entered!: () => void;
			const waiting = new Promise<void>(resolve => { entered = resolve; });
			f.hold(() => { entered(); return new Promise<void>(resolve => { release = resolve; }); });
			let pending;
			if (platform === 'android') pending = f.finish(await f.start('reauth', token));
			else {
				const c = (await f.app.inject({ method: 'POST', url: '/api/v1/auth/challenges', headers: { authorization: 'Bearer ' + token }, payload: { provider: 'apple', platform: 'native', intent: 'reauth' } })).json();
				pending = f.app.inject({ method: 'POST', url: '/api/v1/auth/apple/exchange', headers: { authorization: 'Bearer ' + token }, payload: { challenge: c.id, code: 'valid-' + c.nonce, identityToken: 'valid-' + c.nonce } });
			}
			const running = Promise.resolve(pending); await waiting; f.store.logout(token); release(); const response = await running;
			if (platform === 'android') assert.equal(new URL(response.headers.location!).searchParams.has('handoff'), false);
			else assert.equal(response.statusCode, 401, response.body);
			assert.equal(f.store.session(token), null);
		} finally { await f.app.close(); }
	}
});

test('Android links are delayed until app proof and cannot use another valid session', async () => {
	const f = await fixture();
	try {
		const login = await f.exchange((await f.finish(await f.start())).headers.location!); const token = login.json().token; const id = login.json().account.id;
		const c = await f.start('link', token, 'google'); const done = await f.finish(c);
		assert.equal(f.store.account(id)?.identities.length, 1);
		const otherToken = f.store.createSession(id);
		assert.equal((await f.exchange(done.headers.location!, otherToken)).statusCode, 401);
		assert.equal(f.store.account(id)?.identities.length, 1); assert.ok(f.store.session(token));
		const next = await f.start('link', token, 'google'); const linked = await f.exchange((await f.finish(next)).headers.location!, token);
		assert.equal(linked.statusCode, 200, linked.body); assert.equal(linked.json().token, undefined);
		assert.equal(f.store.account(id)?.identities.length, 2); assert.ok(f.store.session(token));
	} finally { await f.app.close(); }
});
test('Android reauthentication cannot silently create a new provider identity', async () => {
	const f = await fixture();
	try {
		const login = await f.exchange((await f.finish(await f.start())).headers.location!); const token = login.json().token;
		const c = await f.start('reauth', token, 'google'); const response = await f.finish(c);
		assert.equal(new URL(response.headers.location!).searchParams.has('handoff'), false);
		assert.equal(f.store.account(login.json().account.id)?.identities.length, 1);
	} finally { await f.app.close(); }
});
test('forged Android cancellation and concurrent handoff replay never create another session', async () => {
	const f = await fixture();
	try {
		const c = await f.start();
		const cancel = await f.app.inject({ method: 'POST', url: '/api/v1/auth/apple/callback', headers: { cookie: 'sfn_oauth=forged' }, payload: { state: c.id, error: 'access_denied' } });
		assert.equal(cancel.statusCode, 401); assert.equal(cancel.headers.location, undefined);
		const done = await f.finish(await f.start());
		const results = await Promise.all([f.exchange(done.headers.location!), f.exchange(done.headers.location!)]);
		assert.deepEqual(results.map(r => r.statusCode).sort(), [200, 401]);
		const utf8 = new URL((await f.finish(await f.start())).headers.location!); utf8.searchParams.set('state', 'é'.repeat(43));
		assert.equal((await f.exchange(utf8.toString())).statusCode, 401);
	} finally { await f.app.close(); }
});
test('web reauthentication rejects session revocation while provider verification awaits', async () => {
	const f = await fixture();
	try {
		const login = await f.exchange((await f.finish(await f.start())).headers.location!); const token = login.json().token;
		const start = await f.app.inject({ method: 'POST', url: '/api/v1/auth/challenges', headers: { authorization: 'Bearer ' + token, origin: 'https://example.test' }, payload: { provider: 'apple', platform: 'web', intent: 'reauth' } });
		const c = start.json(); const browser = start.cookies.find(c => c.name === 'sfn_oauth')!;
		let release!: () => void; let entered!: () => void;
		const waiting = new Promise<void>(resolve => { entered = resolve; }); f.hold(() => { entered(); return new Promise<void>(resolve => { release = resolve; }); });
		const pending = Promise.resolve(f.app.inject({ method: 'POST', url: '/api/v1/auth/apple/callback', headers: { cookie: browser.name + '=' + browser.value }, payload: { state: c.id, code: 'valid-' + c.nonce } }));
		await waiting; f.store.logout(token); release();
		const response = await pending; assert.equal(response.statusCode, 303); assert.equal(response.headers.location, 'https://example.test/?account=error'); assert.equal(f.store.session(token), null);
	} finally { await f.app.close(); }
});
test('Android handoffs migrate additively and encrypt provider proof at rest', async () => {
	const { mkdtemp, rm, readFile } = await import('node:fs/promises'); const { tmpdir } = await import('node:os'); const { join } = await import('node:path'); const { DatabaseSync } = await import('node:sqlite');
	const directory = await mkdtemp(join(tmpdir(), 'nerds-android-auth-')); const file = join(directory, 'accounts.sqlite'); const key = Buffer.alloc(32, 7);
	try {
		const original = new AccountStore(file, key); const account = original.login({ provider: 'apple', subject: 'existing', clientID: 'app' }); const token = original.createSession(account.id); original.close();
		const legacy = new DatabaseSync(file); legacy.exec('DROP TABLE android_handoffs'); legacy.close();
		const store = new AccountStore(file, key); assert.equal(store.session(token)?.id, account.id);
		const handoff = store.androidHandoff({ challenge: { provider: 'apple', platform: 'android', intent: 'login', userID: null, nonce: 'n', browser: 'b', verifier: 'server-pkce', appChallenge: codeChallenge, appState: state }, identity: { provider: 'apple', subject: 'verified', clientID: 'web', grant: 'provider-grant-must-be-encrypted' } });
		store.close(); assert.equal((await readFile(file)).includes(Buffer.from('provider-grant-must-be-encrypted')), false);
		const reopened = new AccountStore(file, key); assert.equal(reopened.takeAndroidHandoff(handoff)?.identity.grant, 'provider-grant-must-be-encrypted'); assert.equal(reopened.takeAndroidHandoff(handoff), null); assert.equal(reopened.session(token)?.id, account.id); reopened.close();
	} finally { await rm(directory, { recursive: true, force: true }); }
});
