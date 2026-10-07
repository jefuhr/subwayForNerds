import test from 'node:test';
import assert from 'node:assert/strict';
import Fastify from 'fastify';
import { AccountStore } from '../server/account-store';
import { registerAccounts, type AccountOptions } from '../server/accounts';
import { defaults } from '../shared/settings';

const key = Buffer.alloc(32, 7);
test('account identities, sessions, conditional settings and durable revocations are isolated', () => {
	const store = new AccountStore(':memory:', key);
	try {
		const a = store.login({provider:'apple',subject:'a',email:'a@privaterelay.appleid.com',clientID:'app',grant:'secret'});
		const b = store.login({provider:'google',subject:'b',email:'a@privaterelay.appleid.com',clientID:'web',grant:'another'});
		assert.notEqual(a.id, b.id);
		assert.throws(() => store.login({provider:'google',subject:'b',clientID:'web'}, a.id));
		const session = store.createSession(a.id); assert.equal(store.session(session)?.id, a.id);
		const settings = defaults(); settings.theme='night';
		assert.equal(store.putSettings(a.id, 0, settings)?.revision, 1);
		assert.equal(store.putSettings(a.id, 0, defaults()), null);
		assert.equal(store.settings(b.id).settings, null);
		store.deleteAccount(a.id); assert.equal(store.session(session), null);
		assert.equal(store.revocations().length, 1); assert.equal(store.revocations()[0].grant, 'secret');
		assert.equal(store.account(b.id)?.id,b.id);
	} finally { store.close(); }
});
async function fixture() {
	const app=Fastify();
	const options: AccountOptions = {store:new AccountStore(':memory:',key),origin:'https://example.test', providers:{
		apple: {nativeClientID:'app',webClientID:'web',authorize: () => 'https://apple.example/authorize',verify: async (challenge, input) => {
			if((challenge.platform==='web'?input.code:input.identityToken) !== 'valid-'+challenge.nonce) throw new Error('Invalid token');
			return {provider:'apple',subject:'one',clientID:'app',email:'one@example.test',grant:'grant'};
		}, revoke: async () => {}},
		google: {nativeClientID:'ios-google',webClientID:'web-google',authorize: () => 'https://google.example/authorize',verify: async () => {throw new Error('Invalid token');},revoke: async () => {}},
	}};
	await registerAccounts(app,'/api/v1',options); return app;
}
test('native challenges are single use, reject forged proofs, and settings require the owning session', async () => {
	const app=await fixture();
	try {
		const challenge=(await app.inject({method:'POST',url:'/api/v1/auth/challenges',payload:{provider:'apple',platform:'native',intent:'login'}})).json();
		assert.equal((await app.inject({method:'POST',url:'/api/v1/auth/apple/exchange',payload:{challenge:challenge.id,identityToken:'forged',code:'x'}})).statusCode,401);
		const next=(await app.inject({method:'POST',url:'/api/v1/auth/challenges',payload:{provider:'apple',platform:'native',intent:'login'}})).json();
		const body={challenge:next.id,identityToken:'valid-'+next.nonce,code:'x'};
		const login=await app.inject({method:'POST',url:'/api/v1/auth/apple/exchange',payload:body});
		assert.equal(login.statusCode,200); const headers={authorization:'Bearer '+login.json().token};
		assert.equal((await app.inject({method:'POST',url:'/api/v1/auth/apple/exchange',payload:body})).statusCode,401);
		assert.equal((await app.inject('/api/v1/account/settings')).statusCode,401);
		assert.equal((await app.inject({method:'PUT',url:'/api/v1/account/settings',headers:{...headers,'if-match':'"0"'},payload:defaults()})).statusCode,200);
		assert.equal((await app.inject({method:'PUT',url:'/api/v1/account/settings',headers:{...headers,'if-match':'"0"'},payload:defaults()})).statusCode,412);
		assert.equal((await app.inject({method:'POST',url:'/api/v1/auth/logout',headers})).statusCode,204);
		assert.equal((await app.inject({url:'/api/v1/account',headers})).statusCode,401);
	} finally {await app.close();}
});
test('browser login is browser-bound and cookies cannot mutate without CSRF proof', async () => {
	const app=await fixture();
	try {
		assert.equal((await app.inject({method:'POST',url:'/api/v1/auth/challenges',headers:{origin:'https://evil.test'},payload:{provider:'apple',platform:'web',intent:'login'}})).statusCode,403);
		const start=await app.inject({method:'POST',url:'/api/v1/auth/challenges',headers:{origin:'https://example.test'},payload:{provider:'apple',platform:'web',intent:'login'}});
		const c=start.json();
		assert.equal((await app.inject({method:'POST',url:'/api/v1/auth/apple/callback',payload:{state:c.id,code:'x',identityToken:'valid-'+c.nonce}})).statusCode,401);
	} finally {await app.close();}
});

test('provider JWT verification rejects expired tokens, wrong audiences and nonce substitution',async()=>{
	const {generateKeyPair,exportJWK,SignJWT,createLocalJWKSet}=await import('jose');
	const {verifyIdentityToken}=await import('../server/auth-providers');
	const {publicKey,privateKey}=await generateKeyPair('RS256');const jwk=await exportJWK(publicKey);jwk.kid='test';
	const keys=createLocalJWKSet({keys:[jwk]});
	const sign=(audience='app',nonce='nonce',expires='1m')=>new SignJWT({nonce}).setProtectedHeader({alg:'RS256',kid:'test'}).setIssuer('https://issuer.test').setAudience(audience).setSubject('subject').setIssuedAt().setExpirationTime(expires).sign(privateKey);
	assert.equal((await verifyIdentityToken(await sign(),keys,'https://issuer.test','app','nonce')).sub,'subject');
	for(const token of [await sign('wrong'),await sign('app','wrong'),await sign('app','nonce','-1m')])await assert.rejects(()=>verifyIdentityToken(token,keys,'https://issuer.test','app','nonce'));
});
test('web session rejects cookie mutations without CSRF and accepts the bound callback',async()=>{
	const app=await fixture();
	try{
		const start=await app.inject({method:'POST',url:'/api/v1/auth/challenges',headers:{origin:'https://example.test'},payload:{provider:'apple',platform:'web',intent:'login'}});
		const c=start.json(),browserCookie=start.cookies[0].name+'='+start.cookies[0].value;
		// Fixture verifier checks this provider result just as the real verifier checks its ID token.
		const optionsToken='valid-'+c.nonce;
		const done=await app.inject({method:'POST',url:'/api/v1/auth/apple/callback',headers:{cookie:browserCookie},payload:{state:c.id,code:optionsToken}});
		assert.equal(done.statusCode,303);
		const sessionCookie=done.cookies.find(c=>c.name==='__Secure-sfn_session')!;
		assert.ok(sessionCookie);const headers={cookie:sessionCookie.name+'='+sessionCookie.value,origin:'https://example.test'};
		const user=(await app.inject({url:'/api/v1/account',headers})).json();
		assert.equal((await app.inject({method:'PUT',url:'/api/v1/account/settings',headers:{...headers,'if-match':'"0"'},payload:defaults()})).statusCode,403);
		assert.equal((await app.inject({method:'PUT',url:'/api/v1/account/settings',headers:{...headers,'if-match':'"0"','x-sfn-csrf':user.csrf},payload:defaults()})).statusCode,200);
		const reauth=await app.inject({method:'POST',url:'/api/v1/auth/challenges',headers:{...headers,'x-sfn-csrf':user.csrf},payload:{provider:'apple',platform:'web',intent:'reauth'}});
		const rc=reauth.json(),rcookie=reauth.cookies[0];
		// Apple's form POST carries the short-lived SameSite=None binding, not the Lax session cookie.
		assert.equal((await app.inject({method:'POST',url:'/api/v1/auth/apple/callback',headers:{cookie:rcookie.name+'='+rcookie.value},payload:{state:rc.id,code:'valid-'+rc.nonce}})).statusCode,303);
	}finally{await app.close();}
});

test('persisted accounts survive restart, grants stay encrypted, and wrong keys are refused',async()=>{
	const {mkdtemp,rm,readFile}=await import('node:fs/promises');const {tmpdir}=await import('node:os');const {join}=await import('node:path');
	const directory=await mkdtemp(join(tmpdir(),'nerds-accounts-')),file=join(directory,'accounts.sqlite');
	try{
		const store=new AccountStore(file,key);
		const account=store.login({provider:'apple',subject:'durable',clientID:'app',grant:'never-store-this-token-as-plaintext'});
		const token=store.createSession(account.id);store.putSettings(account.id,0,defaults());store.close();
		assert.equal((await readFile(file)).includes(Buffer.from('never-store-this-token-as-plaintext')),false);
		assert.throws(()=>new AccountStore(file,Buffer.alloc(32,9)));
		const restored=new AccountStore(file,key);assert.equal(restored.session(token)?.id,account.id);assert.equal(restored.settings(account.id).revision,1);
		restored.deleteAccount(account.id);restored.close();
		const reopened=new AccountStore(file,key);assert.equal(reopened.session(token),null);assert.equal(reopened.revocations()[0].grant,'never-store-this-token-as-plaintext');reopened.close();
	}finally{await rm(directory,{recursive:true,force:true});}
});
