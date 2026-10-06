import { defaults, validateSettings, type Settings } from '../shared/settings';
import { storage } from './platform';
export type DeviceSettings = {settings:Settings;lastStation:string;sync?:{userID:string;baseline:Settings;revision:number};error?:string};
const key='sfn:settings:v1';
function load():DeviceSettings{
	try{const raw=localStorage.getItem(key);if(raw){const v=JSON.parse(raw);return{settings:validateSettings(v.settings),lastStation:typeof v.lastStation==='string'?v.lastStation:'602',sync:v.sync?{userID:v.sync.userID,baseline:validateSettings(v.sync.baseline),revision:v.sync.revision}:undefined};}}catch{/* Recover legacy preferences if the new record is unreadable. */}
	const settings=defaults();settings.favorites=storage.get('favorites',[]);settings.theme=storage.get('theme','subway');
	const saved=storage.get<{version:number;stations:Record<string,any>}|null>('preferences',null);
	const legacyStation=storage.get<string|null>('station',null);
	const old=saved?.version===1?saved.stations:legacyStation?{[legacyStation]:{direction:storage.get('direction','ALL'),routes:storage.get('routes',[])}}:{};
	settings.stations=Object.fromEntries(Object.entries(old||{}).map(([id,v])=>[id,{direction:v.direction||'ALL',routes:v.routes||[],view:v.view||'track'}]));
	try{return{settings:validateSettings(settings),lastStation:storage.get('station','602')};}catch{return{settings:defaults(),lastStation:'602',error:'Saved settings could not be read. You can restore a .nerds backup.'};}
}
let current=load();
const listeners=new Set<()=>void>();
export const getDeviceSettings=()=>current;
export const subscribeSettings=(listener:()=>void)=>{listeners.add(listener);return()=>{listeners.delete(listener);};};
const notify=()=>listeners.forEach(fn=>fn());
export function saveDeviceSettings(value:DeviceSettings){
	const next={...value,settings:validateSettings(value.settings),error:undefined};
	try{localStorage.setItem(key,JSON.stringify(next));}catch{throw new Error('Settings could not be saved on this device. Free some storage and try again.');}
	current=next;notify();
}
export function updateSettings(update:(value:Settings)=>Settings){
	try{saveDeviceSettings({...current,settings:update(current.settings)});}catch(error){current={...current,error:(error as Error).message};notify();}
}
export function saveLastStation(lastStation:string){try{saveDeviceSettings({...current,lastStation});}catch(error){current={...current,error:(error as Error).message};notify();}}
window.addEventListener('storage',event=>{if(event.key===key){current=load();notify();}});
// Migrate once. Later writes have one source of truth, including native-only fields.
try{if(!localStorage.getItem(key))saveDeviceSettings(current);}catch{/* The first edit will surface the storage failure. */}
