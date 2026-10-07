import { base } from './platform';
import { equal, mergeSettings, type Settings, type SettingsRevision, type Conflict, type Resolutions } from '../shared/settings';
import { getDeviceSettings, saveDeviceSettings, subscribeSettings } from './settings-store';
export type Account={id:string;identities:{provider:'apple'|'google';email:string|null}[]};
type Snapshot={enabled:boolean;ready:boolean;account?:Account;csrf?:string;status:string;error?:string;first?:SettingsRevision;conflicts?:Conflict[]};
class Accounts {
	private value:Snapshot={enabled:false,ready:false,status:'Not signed in'};
	private listeners=new Set<()=>void>();
	private busy=false;private generation=0;private timer?:ReturnType<typeof setInterval>;private debounce?:ReturnType<typeof setTimeout>;private stopSettings?:()=>void;
	private conflicting?:{base:Settings;remote:SettingsRevision};
	get=()=>this.value;
	subscribe=(fn:()=>void)=>{this.listeners.add(fn);return()=>{this.listeners.delete(fn);};};
	private set(patch:Partial<Snapshot>){this.value={...this.value,...patch};this.listeners.forEach(fn=>fn());}
	private async request(path:string,method='GET',body?:unknown,headers:Record<string,string>={}){
		const response=await fetch(base+'api/v1/'+path,{method,credentials:'same-origin',cache:'no-store',headers:{...(body!==undefined?{'content-type':'application/json'}:{}),...(this.value.csrf?{'x-sfn-csrf':this.value.csrf}:{}),...headers},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000)});
		const data=response.status===204?{}:await response.json();
		if(!response.ok)throw Object.assign(new Error(data.error||'Could not sync settings.'),{status:response.status,data});return data;
	}
	start(){
		const generation=++this.generation;
		const outcome=new URLSearchParams(location.search).get('account');
		if(outcome==='error')this.set({error:'Sign-in could not be completed. Please try again.'});
		if(outcome==='cancelled')this.set({status:'Sign-in cancelled'});
		void this.refresh(generation);
		let previous=getDeviceSettings().settings;
		this.stopSettings=subscribeSettings(()=>{const next=getDeviceSettings().settings;if(equal(next,previous))return;previous=next;if(this.value.account)this.set({status:'Changes waiting to sync'});clearTimeout(this.debounce);this.debounce=setTimeout(()=>{void this.sync();},1000);});
		this.timer=setInterval(()=>{if(document.visibilityState==='visible')void this.sync();},30000);
		const resume=()=>{if(document.visibilityState==='visible')void this.refresh(this.generation);};
		window.addEventListener('online',resume);document.addEventListener('visibilitychange',resume);
		return()=>{++this.generation;clearInterval(this.timer);clearTimeout(this.debounce);this.stopSettings?.();window.removeEventListener('online',resume);document.removeEventListener('visibilitychange',resume);};
	}
	private async refresh(generation:number){
		try{
			const config=await this.request('auth/config');if(generation!==this.generation)return;
			this.set({enabled:config.enabled,ready:true});if(!config.enabled)return;
			const result=await this.request('account');if(generation!==this.generation)return;
			if(this.value.account?.id!==result.account.id){++this.generation;this.conflicting=undefined;this.set({first:undefined,conflicts:undefined});}
			this.set({account:result.account,csrf:result.csrf});await this.sync();
		}catch(error){if(generation!==this.generation)return;if((error as any).status===401){this.set({account:undefined,csrf:undefined,status:'Not signed in',first:undefined,conflicts:undefined});}else this.set({ready:true,error:'Account service unavailable. Settings are saved on this device.'});}
	}
	async login(provider:'apple'|'google',intent:'login'|'link'|'reauth'='login'){
		try{const challenge=await this.request('auth/challenges','POST',{provider,platform:'web',intent});location.assign(challenge.authorizationURL);}catch(error){this.set({error:(error as Error).message});}
	}
	async logout(){try{await this.request('auth/logout','POST');this.disconnected();}catch(error){if((error as any).status===401)this.disconnected();else this.set({error:(error as Error).message});}}
	private disconnected(){++this.generation;this.conflicting=undefined;const local=getDeviceSettings();saveDeviceSettings({...local,sync:undefined});this.set({account:undefined,csrf:undefined,status:'Not signed in',first:undefined,conflicts:undefined,error:undefined});}
	async remove(provider?:string){try{await this.request('account'+(provider?'/identities/'+provider:''),'DELETE');this.disconnected();}catch(error){this.set({error:(error as Error).message});}}
	async chooseInitial(choice:'local'|'remote'){
		const remote=this.value.first,userID=this.value.account?.id;if(!remote?.settings||!userID)return;
		try{const local=getDeviceSettings();saveDeviceSettings({...local,settings:choice==='remote'?remote.settings:local.settings,sync:{userID,baseline:remote.settings,revision:remote.revision}});this.set({first:undefined,error:undefined});await this.sync();}catch(error){this.set({error:(error as Error).message});}
	}
	async resolve(choices:Resolutions){
		const conflict=this.conflicting,userID=this.value.account?.id;if(!conflict?.remote.settings||!userID)return;
		try{const local=getDeviceSettings();const merged=mergeSettings(conflict.base,local.settings,conflict.remote.settings,choices);
			if(merged.conflicts.length){this.set({conflicts:merged.conflicts});return;}
			saveDeviceSettings({...local,settings:merged.settings,sync:{userID,baseline:conflict.remote.settings,revision:conflict.remote.revision}});
			this.conflicting=undefined;this.set({conflicts:undefined,error:undefined});await this.sync();
		}catch(error){this.set({error:(error as Error).message});}
	}
	async sync(){
		const account=this.value.account;if(!account||this.busy||this.value.first||this.value.conflicts)return;
		if(!navigator.onLine){this.set({status:'Offline — changes saved on this device'});return;}
		this.busy=true;const generation=this.generation;
		try{
			this.set({status:'Syncing…',error:undefined});
			const remote:SettingsRevision=await this.request('account/settings');if(generation!==this.generation)return;
			const local=getDeviceSettings();if(local.error)throw new Error(local.error);
			const baseline=local.sync?.userID===account.id?local.sync.baseline:undefined;
			if(!baseline&&remote.settings&&!equal(local.settings,remote.settings)){this.set({first:remote,status:'Choose settings to start syncing'});return;}
			const merged=remote.settings&&baseline?mergeSettings(baseline,local.settings,remote.settings):{settings:local.settings,conflicts:[]};
			if(merged.conflicts.length){this.conflicting={base:baseline!,remote};this.set({conflicts:merged.conflicts,status:'Choose which changes to keep'});return;}
			const accepted:SettingsRevision=equal(merged.settings,remote.settings)?remote:await this.request('account/settings','PUT',merged.settings,{'if-match':'"'+remote.revision+'"'});
			if(generation!==this.generation)return;
			// Edits made while the upload was in flight remain pending, rather than disappearing.
			const latest=getDeviceSettings();const rebase=mergeSettings(local.settings,latest.settings,accepted.settings!);
			saveDeviceSettings({...latest,settings:rebase.settings,sync:{userID:account.id,baseline:accepted.settings!,revision:accepted.revision}});
			if(rebase.conflicts.length){this.conflicting={base:local.settings,remote:accepted};this.set({conflicts:rebase.conflicts,status:'Choose which changes to keep'});}
			else this.set({status:equal(rebase.settings,accepted.settings)?'Settings synced':'Changes waiting to sync'});
		}catch(error){if(generation!==this.generation)return;
			if((error as any).status===401)this.set({account:undefined,csrf:undefined,status:'Sign in again to sync. Changes are saved on this device.'});
			else if((error as any).status===412){this.set({status:'New account changes — retrying…'});this.debounce=setTimeout(()=>{void this.sync();},1000);}
			else this.set({status:'Changes saved on this device',error:(error as Error).message});
		}finally{this.busy=false;if(generation!==this.generation&&this.value.account)queueMicrotask(()=>{void this.sync();});}
	}
}
export const accounts=new Accounts();
