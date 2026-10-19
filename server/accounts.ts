import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import cookie from '@fastify/cookie';
import rateLimit from '@fastify/rate-limit';
import { join } from 'node:path';
import { createHash, timingSafeEqual } from 'node:crypto';
import { AccountStore, hash, secret, type ProviderName, type Challenge, type Identity } from './account-store';
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
export const ANDROID_AUTH_CALLBACK='nyc.juliet.subwaysfornerds://auth/android';
const appProof=(value:unknown)=>typeof value==='string'&&/^[A-Za-z0-9_-]{43}$/.test(value)?value:fail(400,'Android sign-in requires S256 proof.');
const sameSecret=(a:string,b:string)=>{const left=Buffer.from(a),right=Buffer.from(b);return left.length===right.length&&timingSafeEqual(left,right);};
export async function registerAccounts(app:FastifyInstance,api:string,options?:AccountOptions,{exemptLoopback=false}:{exemptLoopback?:boolean}={}){
	await app.register(async auth=>{
		await auth.register(cookie);
		// Parallel browser suites share one loopback client; production keys every client separately.
		await auth.register(rateLimit,{max:120,timeWindow:60000,allowList:exemptLoopback?['127.0.0.1','::1']:[]});
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
		const recent=(req:FastifyRequest)=>{const user=mutation(req);if(store.currentTime()-user.authenticatedAt>600)fail(403,'Sign in again before changing login methods or deleting your account.');return user;};
		const setSession=(reply:FastifyReply,value:string)=>reply.setCookie(cookieName,value,{httpOnly:true,secure:true,sameSite:'lax',path:root,maxAge:30*86400});
		const clearSession=(reply:FastifyReply)=>reply.clearCookie(cookieName,{httpOnly:true,secure:true,sameSite:'lax',path:root});
		const callback=(provider:ProviderName)=>origin+api+'/auth/'+provider+'/callback';
		const originalSession=(c:Challenge,req?:FastifyRequest)=>{
			if(c.userID&&(store.sessionByHash(c.sessionHash||'')?.id!==c.userID||(req&&hash(token(req))!==c.sessionHash)))fail(401,'Your account changed during sign-in. Please try again.');
		};
		const androidRedirect=(c:Challenge,values:Record<string,string>)=>ANDROID_AUTH_CALLBACK+'?'+new URLSearchParams({state:c.appState!,...values});
		auth.post<{Body:{provider?:unknown;platform?:unknown;intent?:unknown;codeChallenge?:unknown;codeChallengeMethod?:unknown;state?:unknown}}>(api+'/auth/challenges',{config:{rateLimit:{max:20,timeWindow:60000}}},async(req,reply)=>{
			checkOrigin(req);
			const provider=providerName(req.body?.provider),platform=req.body?.platform,intent=req.body?.intent||'login';
			if(!['native','web','android'].includes(platform as string)||!['login','link','reauth'].includes(intent as string))fail(400,'Invalid login request.');
			if(platform==='android'&&(req.body.codeChallengeMethod!=='S256'||Object.keys(req.body).some(k=>!['provider','platform','intent','codeChallenge','codeChallengeMethod','state'].includes(k))))fail(400,'Android sign-in requires S256 proof and the fixed app callback.');
			const appChallenge=platform==='android'?appProof(req.body.codeChallenge):undefined;
			const appState=platform==='android'?appProof(req.body.state):undefined;
			if(platform==='web'&&req.headers.origin!==origin)fail(403,'Start sign-in from this app.');
			const userID=intent==='link'?recent(req).id:intent==='reauth'?mutation(req).id:null;
			const browser=platform==='web'?(req.cookies.sfn_oauth||secret()):null;
			if(browser)reply.setCookie('sfn_oauth',browser,{httpOnly:true,secure:true,sameSite:'none',path:api+'/auth/',maxAge:300});
			const c:Challenge={provider,platform:platform as Challenge['platform'],intent:intent as Challenge['intent'],userID,nonce:secret(),browser:browser?hash(browser):null,verifier:secret(),sessionHash:userID?hash(token(req)):undefined,appChallenge,appState};
			const id=store.challenge(c);return{id,nonce:c.nonce,authorizationURL:platform==='android'?origin+api+'/auth/android/start?'+new URLSearchParams({challenge:id}):platform==='web'?providers[provider].authorize(c,id,callback(provider)):undefined};
		});
		auth.get<{Querystring:{challenge?:unknown}}>(api+'/auth/android/start',async(req,reply)=>{
			const browser=req.cookies.sfn_oauth||secret();
			const c=store.bindAndroidChallenge(text(req.query.challenge),hash(browser));
			if(!c)fail(401,'Sign-in expired or began in another browser. Please try again.');
			originalSession(c);
			reply.setCookie('sfn_oauth',browser,{httpOnly:true,secure:true,sameSite:'none',path:api+'/auth/',maxAge:300});
			return reply.code(303).redirect(providers[c.provider].authorize(c,text(req.query.challenge),callback(c.provider)));
		});
		const complete=(c:Challenge,identity:Identity,req:FastifyRequest,reply:FastifyReply)=>{
			originalSession(c,c.platform==='web'?undefined:req);
			if(c.intent==='reauth'){
				// Never create/link an identity as a side effect of reauthentication.
				if(!store.ownsIdentity(c.userID!,identity))fail(401,'Use a login already linked to this account.');
				store.login(identity,c.userID!);
				store.reauthenticateHash(c.sessionHash!);return{account:store.account(c.userID!),csrf:hash('csrf:'+token(req))};
			}
			let account;try{account=store.login(identity,c.intent==='link'?c.userID!:undefined);}catch(error){fail(409,(error as Error).message);}
			if(c.intent==='link')return{account,csrf:hash('csrf:'+token(req))};
			if(token(req))store.logout(token(req));
			const value=store.createSession(account!.id);
			if(c.platform==='web')setSession(reply,value);
			return{account,csrf:hash('csrf:'+value),...(c.platform!=='web'?{token:value}:{})};
		};
		const finish=async(req:FastifyRequest,reply:FastifyReply,provider:ProviderName,id:string,input:LoginInput,platform:'native'|'browser')=>{
			const c=store.takeChallenge(id);
			if(!c||c.provider!==provider||(platform==='native'?c.platform!=='native':c.platform==='native'))fail(401,'Sign-in expired. Please try again.');
			if(c.platform!=='native'&&(!req.cookies.sfn_oauth||c.browser!==hash(req.cookies.sfn_oauth)))fail(401,'Sign-in must finish in the browser where it began.');
			try{
				originalSession(c,c.platform==='native'?req:undefined);
				let identity;try{identity=await providers[provider].verify(c,input,callback(provider));}catch{fail(401,'Sign-in could not be verified. Please try again.');}
				// Verification awaits a provider: logout/unlink/delete can revoke the original session meanwhile.
				originalSession(c,c.platform==='native'?req:undefined);
				if(c.expiresAt!==undefined&&store.currentTime()>=c.expiresAt)fail(401,'Sign-in expired. Please try again.');
				if(c.platform==='android'){
					if(c.intent==='reauth'&&!store.ownsIdentity(c.userID!,identity))fail(401,'Use a login already linked to this account.');
					return{androidRedirect:androidRedirect(c,{handoff:store.androidHandoff({challenge:c,identity})})};
				}
				return complete(c,identity,req,reply);
			}catch(error){
				if(c.platform==='android')return{androidRedirect:androidRedirect(c,{error:'error'})};
				if(c.platform==='web')return{webError:true};
				throw error;
			}
		};
		auth.post<{Body:{handoff?:unknown;state?:unknown;verifier?:unknown}}>(api+'/auth/android/exchange',{config:{rateLimit:{max:20,timeWindow:60000}}},async(req,reply)=>{
			checkOrigin(req);
			const handoff=store.takeAndroidHandoff(text(req.body?.handoff));
			if(!handoff||typeof req.body.verifier!=='string'||!/^[A-Za-z0-9._~-]{43,128}$/.test(req.body.verifier)||
				typeof req.body.state!=='string'||!sameSecret(handoff.challenge.appState||'',req.body.state)||
				!sameSecret(handoff.challenge.appChallenge||'',createHash('sha256').update(req.body.verifier).digest('base64url')))fail(401,'Sign-in proof expired or did not match this app. Please try again.');
			return complete(handoff.challenge,handoff.identity,req,reply);
		});
		auth.post<{Params:{provider:string};Body:{challenge:string;code:string;identityToken:string}}>(api+'/auth/:provider/exchange',{config:{rateLimit:{max:20,timeWindow:60000}}},async(req,reply)=>{
			checkOrigin(req);return finish(req,reply,providerName(req.params.provider),text(req.body?.challenge),{code:text(req.body?.code),identityToken:text(req.body?.identityToken)},'native');
		});
		auth.addContentTypeParser('application/x-www-form-urlencoded',{parseAs:'string',bodyLimit:32000},(_req,body,done)=>done(null,Object.fromEntries(new URLSearchParams(body as string))));
		auth.route<{Params:{provider:string};Body:Record<string,string>;Querystring:Record<string,string>}>({method:['GET','POST'],url:api+'/auth/:provider/callback',bodyLimit:32000,handler:async(req,reply)=>{
			const data=req.method==='GET'?req.query:req.body;
			const provider=providerName(req.params.provider);
			if(data?.error){
				const c=store.takeChallenge(text(data.state));
				if(!c||c.provider!==provider||c.platform==='native'||!req.cookies.sfn_oauth||c.browser!==hash(req.cookies.sfn_oauth))fail(401,'Sign-in expired. Please try again.');
				if(c.platform==='android')return reply.code(303).redirect(androidRedirect(c,{error:data.error==='access_denied'?'cancelled':'error'}));
				return reply.code(303).redirect(origin+root+'?account='+ (data.error==='access_denied'?'cancelled':'error'));
			}
			const result=await finish(req,reply,provider,text(data?.state),{code:text(data?.code)},'browser');
			if('androidRedirect' in result)return reply.code(303).redirect(result.androidRedirect!);
			return reply.code(303).redirect(origin+root+'?account='+('webError' in result?'error':'connected'));
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
					(!Object.hasOwn(incoming.widgets,'stationSelection')&&!equal(current.widgets.stationSelection,baseline.widgets.stationSelection))||
					(!Object.hasOwn(incoming,'units')&&!equal(current.units,baseline.units))||
					(!Object.hasOwn(incoming,'offline')&&!equal(current.offline,baseline.offline))||
					(!Object.hasOwn(incoming,'combinedStations')&&!equal(current.combinedStations,baseline.combinedStations))||
					(!Object.hasOwn(incoming,'hiddenRoutes')&&!equal(current.hiddenRoutes,baseline.hiddenRoutes))||
					(!Object.hasOwn(incoming,'transfers')&&!equal(current.transfers,baseline.transfers))||
					(!Object.hasOwn(incoming,'departureRows')&&!equal(current.departureRows,baseline.departureRows)))
					fail(409,'Update Subway Nerds before syncing. This client cannot preserve your saved trains, station selection, unit, offline settings, combined stations, hidden lines, transfer filters, or row display settings.');
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
