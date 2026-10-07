import { createRemoteJWKSet, importPKCS8, jwtVerify, SignJWT, type JWTVerifyGetKey } from 'jose';
import { createHash, createPrivateKey } from 'node:crypto';
import type { Challenge, Identity, ProviderName } from './account-store';
export type LoginInput = {code:string;identityToken?:string};
export type AuthProvider = {
	nativeClientID:string; webClientID:string;
	authorize:(challenge:Challenge,state:string,redirect:string)=>string;
	verify:(challenge:Challenge,input:LoginInput,redirect:string)=>Promise<Identity>;
	revoke:(clientID:string,grant:string)=>Promise<void>;
};
export async function verifyIdentityToken(token:string,key:JWTVerifyGetKey,issuer:string|string[],audience:string,nonce:string) {
	const {payload}=await jwtVerify(token,key,{issuer,audience,algorithms:['RS256'],requiredClaims:['sub','iat','exp','nonce'],clockTolerance:5});
	if(!payload.sub||payload.nonce!==nonce||typeof payload.iat!=='number'||payload.iat>Date.now()/1000+5)throw new Error('Invalid identity token');
	return payload;
}
async function form(url:string,values:Record<string,string>){
	const response=await fetch(url,{method:'POST',headers:{'content-type':'application/x-www-form-urlencoded'},body:new URLSearchParams(values),signal:AbortSignal.timeout(10000)});
	const data=await response.json() as any;
	if(!response.ok||data.error)throw new Error('Provider exchange failed');return data;
}
export function productionProviders(env:NodeJS.ProcessEnv):Record<ProviderName,AuthProvider> {
	const required=(name:string)=>{const value=env[name];if(!value)throw new Error('Missing '+name);return value;};
	const appleNative=required('SFN_APPLE_APP_ID'),appleWeb=required('SFN_APPLE_SERVICES_ID'),team=required('SFN_APPLE_TEAM_ID'),kid=required('SFN_APPLE_KEY_ID'),pem=required('SFN_APPLE_PRIVATE_KEY').replaceAll('\\n','\n');
	const appleKey=createPrivateKey(pem);
	if(appleKey.asymmetricKeyType!=='ec'||appleKey.asymmetricKeyDetails?.namedCurve!=='prime256v1')throw new Error('Apple requires a P-256 signing key');
	const googleNative=required('SFN_GOOGLE_IOS_CLIENT_ID'),googleWeb=required('SFN_GOOGLE_WEB_CLIENT_ID'),googleSecret=required('SFN_GOOGLE_CLIENT_SECRET');
	const appleKeys=createRemoteJWKSet(new URL('https://appleid.apple.com/auth/keys'));
	const googleKeys=createRemoteJWKSet(new URL('https://www.googleapis.com/oauth2/v3/certs'));
	const appleSecret=async(clientID:string)=>new SignJWT({}).setProtectedHeader({alg:'ES256',kid}).setIssuer(team).setSubject(clientID).setAudience('https://appleid.apple.com').setIssuedAt().setExpirationTime('5m').sign(await importPKCS8(pem,'ES256'));
	const revoke=async(url:string,values:Record<string,string>)=>{
		const response=await fetch(url,{method:'POST',headers:{'content-type':'application/x-www-form-urlencoded'},body:new URLSearchParams(values),signal:AbortSignal.timeout(10000)});
		if(response.ok)return;
		const data=await response.json().catch(()=>({}));
		if(data.error==='invalid_token')return; // Already revoked or expired.
		throw new Error('Provider revocation pending');
	};
	return {
		apple:{nativeClientID:appleNative,webClientID:appleWeb,
			authorize:(c,state,redirect)=>'https://appleid.apple.com/auth/authorize?'+new URLSearchParams({client_id:appleWeb,redirect_uri:redirect,response_type:'code',response_mode:'form_post',scope:'email',state,nonce:c.nonce}),
			verify:async(c,input,redirect)=>{
				const clientID=c.platform==='native'?appleNative:appleWeb;
				const result=await form('https://appleid.apple.com/auth/token',{client_id:clientID,client_secret:await appleSecret(clientID),code:input.code,grant_type:'authorization_code',...(c.platform==='web'?{redirect_uri:redirect}:{})});
				const payload=await verifyIdentityToken(result.id_token,appleKeys,'https://appleid.apple.com',clientID,c.nonce);
				if(c.platform==='native'){
					const original=await verifyIdentityToken(input.identityToken||'',appleKeys,'https://appleid.apple.com',clientID,c.nonce);
					if(original.sub!==payload.sub)throw new Error('Identity mismatch');
				}
				if(!result.refresh_token)throw new Error('Missing Apple grant');
				return{provider:'apple',subject:payload.sub!,email:typeof payload.email==='string'?payload.email:undefined,clientID,grant:result.refresh_token};
			},
			revoke:async(clientID,grant)=>revoke('https://appleid.apple.com/auth/revoke',{client_id:clientID,client_secret:await appleSecret(clientID),token:grant,token_type_hint:'refresh_token'}),
		},
		google:{nativeClientID:googleNative,webClientID:googleWeb,
			authorize:(c,state,redirect)=>'https://accounts.google.com/o/oauth2/v2/auth?'+new URLSearchParams({client_id:googleWeb,redirect_uri:redirect,response_type:'code',scope:'openid email',state,nonce:c.nonce,access_type:'offline',code_challenge:createHash('sha256').update(c.verifier).digest('base64url'),code_challenge_method:'S256'}),
			verify:async(c,input,redirect)=>{
				const result=await form('https://oauth2.googleapis.com/token',{client_id:googleWeb,client_secret:googleSecret,code:input.code,grant_type:'authorization_code',redirect_uri:c.platform==='web'?redirect:'',...(c.platform==='web'?{code_verifier:c.verifier}:{})});
				const payload=await verifyIdentityToken(c.platform==='native'?input.identityToken||'':result.id_token,googleKeys,['https://accounts.google.com','accounts.google.com'],googleWeb,c.nonce);
				const exchanged=await jwtVerify(result.id_token,googleKeys,{issuer:['https://accounts.google.com','accounts.google.com'],audience:googleWeb,algorithms:['RS256']});
				if(exchanged.payload.sub!==payload.sub)throw new Error('Identity mismatch');
				if(c.platform==='native'&&payload.azp!==googleNative&&payload.azp!==googleWeb)throw new Error('Invalid authorized client');
				return{provider:'google',subject:payload.sub!,email:typeof payload.email==='string'?payload.email:undefined,clientID:googleWeb,grant:result.refresh_token};
			},
			revoke:async(_clientID,grant)=>revoke('https://oauth2.googleapis.com/revoke',{token:grant}),
		},
	};
}
