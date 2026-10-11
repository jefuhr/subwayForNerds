import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import cookie from '@fastify/cookie';
import rateLimit from '@fastify/rate-limit';
import { join } from 'node:path';
import { AccountStore, hash, secret, type ProviderName, type Challenge } from './account-store';
import { productionProviders, type AuthProvider, type LoginInput } from './auth-providers';
import { validateSettings, defaults, equal, MAX_SETTINGS_BYTES } from '../shared/settings';
export type AccountOptions = {store:AccountStore;origin:string;providers:Record<ProviderName,AuthProvider>};
export function accountOptions(env=process.env):AccountOptions|undefined{
	if(env.SFN_AUTH_ENABLED!=='true')return;
	const origin=new URL(env.SFN_AUTH_ORIGIN||'https://juliet.nyc');
	if(origin.protocol!=='https:'||origin.pathname!=='/'||origin.search||origin.hash||origin.username||origin.password)throw new Error('Authentication requires an HTTPS origin');
	const key=Buffer.from(env.SFN_ACCOUNT_ENCRYPTION_KEY||'','base64');
	const providers=productionProviders(env);
	return{origin:origin.origin,providers,store:new AccountStore(join(env.STATE_DIR||'state','accounts.sqlite'),key)};
}
function fail(statusCode:number,message:string):never{throw Object.assign(new Error(message),{statusCode});}
const providerName=(v:unknown):ProviderName=>v==='apple'||v==='google'?v:fail(400,'Choose Apple or Google.');
const text=(value:unknown)=>typeof value==='string'&&value.length>0&&value.length<16000?value:fail(400,'Invalid login request.');
export async function registerAccounts(app:FastifyInstance,api:string,options?:AccountOptions){
	await app.register(async auth=>{
		await auth.register(cookie);
		await auth.register(rateLimit,{max:120,timeWindow:60000});
		auth.addHook('onRequest',async(_req,reply)=>{reply.header('Cache-Control','no-store');});
		auth.setErrorHandler((error,_req,reply)=>{const status=(error as any).statusCode||500;reply.code(status).send({error:status>=500?'Account service unavailable. Your settings remain on this device.':(error as Error).message});});
		auth.get(api+'/auth/config',()=>({enabled:!!options,googleClientID:options?.providers.google.nativeClientID,googleServerClientID:options?.providers.google.webClientID}));
		if(!options)return;
		const {store,origin,providers}=options;
		const root=api.replace(/api\/v1$/,'');
		const cookieName='__Secure-sfn_session';
		const token=(req:FastifyRequest)=>req.headers.authorization?.startsWith('Bearer ')?req.headers.authorization.slice(7):req.cookies[cookieName]||'';
		const session=(req:FastifyRequest)=>store.session(token(req))||fail(401,'Sign in to sync your settings.');
		const checkOrigin=(req:FastifyRequest)=>{if(req.headers.origin&&req.headers.origin!==origin)fail(403,'This request came from another site.');};
		const mutation=(req:FastifyRequest)=>{
			checkOrigin(req);const user=session(req);
			if(!req.headers.authorization?.startsWith('Bearer ')&&(req.headers.origin!==origin||req.headers['x-sfn-csrf']!==hash('csrf:'+token(req))))fail(403,'Please reopen settings and try again.');return user;
		};
		const recent=(req:FastifyRequest)=>{const user=mutation(req);if(Date.now()/1000-user.authenticatedAt>600)fail(403,'Sign in again before changing login methods or deleting your account.');return user;};
		const setSession=(reply:FastifyReply,value:string)=>reply.setCookie(cookieName,value,{httpOnly:true,secure:true,sameSite:'lax',path:root,maxAge:30*86400});
		const clearSession=(reply:FastifyReply)=>reply.clearCookie(cookieName,{httpOnly:true,secure:true,sameSite:'lax',path:root});
		const callback=(provider:ProviderName)=>origin+api+'/auth/'+provider+'/callback';
		auth.post<{Body:{provider?:unknown;platform?:unknown;intent?:unknown}}>(api+'/auth/challenges',{config:{rateLimit:{max:20,timeWindow:60000}}},async(req,reply)=>{
			checkOrigin(req);
			const provider=providerName(req.body?.provider),platform=req.body?.platform,intent=req.body?.intent||'login';
			if(!['native','web'].includes(platform as string)||!['login','link','reauth'].includes(intent as string))fail(400,'Invalid login request.');
			if(platform==='web'&&req.headers.origin!==origin)fail(403,'Start sign-in from this app.');
			const userID=intent==='link'?recent(req).id:intent==='reauth'?mutation(req).id:null;
			const browser=platform==='web'?(req.cookies.sfn_oauth||secret()):null;
			if(browser)reply.setCookie('sfn_oauth',browser,{httpOnly:true,secure:true,sameSite:'none',path:api+'/auth/',maxAge:300});
			const c:Challenge={provider,platform:platform as Challenge['platform'],intent:intent as Challenge['intent'],userID,nonce:secret(),browser:browser?hash(browser):null,verifier:secret(),sessionHash:userID?hash(token(req)):undefined};
			const id=store.challenge(c);return{id,nonce:c.nonce,authorizationURL:platform==='web'?providers[provider].authorize(c,id,callback(provider)):undefined};
		});
		const finish=async(req:FastifyRequest,reply:FastifyReply,provider:ProviderName,id:string,input:LoginInput,platform:'native'|'web')=>{
			const c=store.takeChallenge(id);
			if(!c||c.provider!==provider||c.platform!==platform)fail(401,'Sign-in expired. Please try again.');
			if(platform==='web'&&(!req.cookies.sfn_oauth||c.browser!==hash(req.cookies.sfn_oauth)))fail(401,'Sign-in must finish in the browser where it began.');
			if(c.userID&&(store.sessionByHash(c.sessionHash||'')?.id!==c.userID||(platform==='native'&&hash(token(req))!==c.sessionHash)))fail(401,'Your account changed during sign-in. Please try again.');
			let identity;try{identity=await providers[provider].verify(c,input,callback(provider));}catch{fail(401,'Sign-in could not be verified. Please try again.');}
			if(c.intent==='reauth'){
				// Never create/link an identity as a side effect of reauthentication.
				if(!store.ownsIdentity(c.userID!,identity!))fail(401,'Use a login already linked to this account.');
				store.login(identity!,c.userID!);
				store.reauthenticateHash(c.sessionHash!);return{account:store.account(c.userID!),csrf:hash('csrf:'+token(req))};
			}
			let account;try{account=store.login(identity!,c.intent==='link'?c.userID!:undefined);}catch(error){fail(409,(error as Error).message);}
			if(c.intent==='link')return{account,csrf:hash('csrf:'+token(req))};
			if(token(req))store.logout(token(req));
			const value=store.createSession(account!.id);
			if(platform==='web')setSession(reply,value);
			return{account,csrf:hash('csrf:'+value),...(platform==='native'?{token:value}:{})};
		};
		auth.post<{Params:{provider:string};Body:{challenge:string;code:string;identityToken:string}}>(api+'/auth/:provider/exchange',{config:{rateLimit:{max:20,timeWindow:60000}}},async(req,reply)=>{
			checkOrigin(req);return finish(req,reply,providerName(req.params.provider),text(req.body?.challenge),{code:text(req.body?.code),identityToken:text(req.body?.identityToken)},'native');
		});
		auth.addContentTypeParser('application/x-www-form-urlencoded',{parseAs:'string',bodyLimit:32000},(_req,body,done)=>done(null,Object.fromEntries(new URLSearchParams(body as string))));
		auth.route<{Params:{provider:string};Body:Record<string,string>;Querystring:Record<string,string>}>({method:['GET','POST'],url:api+'/auth/:provider/callback',bodyLimit:32000,handler:async(req,reply)=>{
			const data=req.method==='GET'?req.query:req.body;
			const provider=providerName(req.params.provider);
			if(data?.error){
				const c=store.takeChallenge(text(data.state));
				if(!c||c.provider!==provider||c.platform!=='web'||!req.cookies.sfn_oauth||c.browser!==hash(req.cookies.sfn_oauth))fail(401,'Sign-in expired. Please try again.');
				return reply.code(303).redirect(origin+root+'?account='+ (data.error==='access_denied'?'cancelled':'error'));
			}
			try{await finish(req,reply,provider,text(data?.state),{code:text(data?.code)},'web');}
			catch(error){if(req.cookies.sfn_oauth)return reply.code(303).redirect(origin+root+'?account=error');throw error;}
			return reply.code(303).redirect(origin+root+'?account=connected');
		}});
		auth.get(api+'/account',async req=>({account:session(req),csrf:hash('csrf:'+token(req))}));
		auth.post(api+'/auth/logout',async(req,reply)=>{mutation(req);store.logout(token(req));clearSession(reply);return reply.code(204).send();});
		auth.get(api+'/account/settings',async(req,reply)=>{const result=store.settings(session(req).id);reply.header('ETag','"'+result.revision+'"');return result;});
		auth.put(api+'/account/settings',{bodyLimit:MAX_SETTINGS_BYTES},async(req,reply)=>{
			const user=mutation(req);const match=/^"(\d+)"$/.exec(String(req.headers['if-match']||''));if(!match)fail(428,'Reload account settings before saving.');
			let settings;try{settings=validateSettings(req.body);}catch(error){fail(400,(error as Error).message);}
			const stored=store.settings(user.id);
			if(stored.revision!==Number(match![1]))return reply.code(412).send(stored);
			if(stored.settings){
				const current=validateSettings(stored.settings),baseline=defaults(),incoming=req.body as Record<string,any>;
				if((!Object.hasOwn(incoming,'trainFavorites')&&!equal(current.trainFavorites,baseline.trainFavorites))||
					(!Object.hasOwn(incoming,'stationSelection')&&!equal(current.stationSelection,baseline.stationSelection))||
					(!Object.hasOwn(incoming.widgets,'stationSelection')&&!equal(current.widgets.stationSelection,baseline.widgets.stationSelection)))
					fail(409,'Update Subway Nerds before syncing. This client cannot preserve your saved trains and station selection.');
			}
			const result=store.putSettings(user.id,Number(match![1]),settings!);
			if(!result)return reply.code(412).send(store.settings(user.id));
			return reply.header('ETag','"'+result.revision+'"').send(result);
		});
		auth.delete<{Params:{provider:string}}>(api+'/account/identities/:provider',async(req,reply)=>{
			const user=recent(req);try{store.unlink(user.id,providerName(req.params.provider));}catch(error){fail(409,(error as Error).message);}
			clearSession(reply);void drain();return reply.code(204).send();
		});
		auth.delete(api+'/account',async(req,reply)=>{store.deleteAccount(recent(req).id);clearSession(reply);void drain();return reply.code(204).send();});
		let draining:Promise<void>|undefined;
		const drain=()=>{ if(draining)return draining; draining=(async()=>{
			try{for(const job of store.revocations()){try{await providers[job.provider].revoke(job.clientID,job.grant);store.finishRevocation(job.id);}catch{auth.log.warn('Provider revocation remains queued');}}}catch{auth.log.error('Could not process queued provider revocations');}
		})().finally(()=>{draining=undefined;}); return draining; };
		const timer=setInterval(()=>{void drain();},60000);timer.unref();
		auth.addHook('onReady',async()=>{void drain();});
		auth.addHook('onClose',async()=>{clearInterval(timer);await draining;store.close();});
	});
}
