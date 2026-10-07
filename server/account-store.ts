import { DatabaseSync } from 'node:sqlite';
import { createHash, randomBytes, randomUUID, createCipheriv, createDecipheriv } from 'node:crypto';
import { mkdirSync, chmodSync } from 'node:fs';
import { dirname } from 'node:path';
import type { Settings, SettingsRevision } from '../shared/settings';
export type ProviderName = 'apple' | 'google';
export type Identity = {provider: ProviderName; subject: string; email?: string; clientID: string; grant?: string};
export type Account = {id:string; identities: {provider:ProviderName;email:string|null}[]};
export type Challenge = {provider:ProviderName;platform:'native'|'web';intent:'login'|'link'|'reauth';userID:string|null;nonce:string;browser:string|null;verifier:string;sessionHash?:string};
export const secret = () => randomBytes(32).toString('base64url');
export const hash = (value:string) => createHash('sha256').update(value).digest('hex');
const now = () => Math.floor(Date.now()/1000);
export class AccountStore {
	private db: DatabaseSync;
	constructor(file:string, private key:Uint8Array) {
		if(key.length!==32) throw new Error('Account encryption key must contain 32 bytes');
		if(file!==':memory:') mkdirSync(dirname(file),{recursive:true});
		this.db=new DatabaseSync(file);
		if(file!==':memory:')chmodSync(file,0o600);
		this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=3000;
		CREATE TABLE IF NOT EXISTS account_schema(version INTEGER PRIMARY KEY);
		INSERT OR IGNORE INTO account_schema VALUES(1);
		CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY, created_at INTEGER NOT NULL);
		CREATE TABLE IF NOT EXISTS identities(provider TEXT NOT NULL, subject TEXT NOT NULL,user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,email TEXT,PRIMARY KEY(provider,subject),UNIQUE(user_id,provider));
		CREATE TABLE IF NOT EXISTS grants(provider TEXT NOT NULL,subject TEXT NOT NULL,client_id TEXT NOT NULL,user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,grant TEXT NOT NULL,PRIMARY KEY(provider,subject,client_id));
		CREATE TABLE IF NOT EXISTS sessions(hash TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,expires INTEGER NOT NULL,authenticated_at INTEGER NOT NULL);
		CREATE TABLE IF NOT EXISTS challenges(hash TEXT PRIMARY KEY,expires INTEGER NOT NULL,data TEXT NOT NULL);
		CREATE TABLE IF NOT EXISTS settings(user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,revision INTEGER NOT NULL,data TEXT NOT NULL);
		CREATE TABLE IF NOT EXISTS revocations(id TEXT PRIMARY KEY,provider TEXT NOT NULL,client_id TEXT NOT NULL,grant TEXT NOT NULL);
		CREATE TABLE IF NOT EXISTS account_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
		CREATE TABLE IF NOT EXISTS account_deletions(id TEXT PRIMARY KEY,deleted_at INTEGER NOT NULL);`);
		if((this.db.prepare('SELECT MAX(version) AS version FROM account_schema').get() as any).version!==1) {this.db.close();throw new Error('Unsupported account schema');}
		try {
			const check=this.db.prepare("SELECT value FROM account_meta WHERE key='encryption-check'").get() as {value:string}|undefined;
			if(check&&this.decrypt(check.value)!=='subway-accounts-v1')throw new Error('Account encryption key does not match');
			if(!check)this.db.prepare('INSERT INTO account_meta VALUES(?,?)').run('encryption-check',this.encrypt('subway-accounts-v1'));
		}catch(error){this.db.close();throw error;}
	}
	close(){this.db.close();}
	private transaction<T>(fn:()=>T):T{this.db.exec('BEGIN IMMEDIATE');try{const r=fn();this.db.exec('COMMIT');return r;}catch(e){this.db.exec('ROLLBACK');throw e;}}
	private encrypt(value:string){const iv=randomBytes(12),cipher=createCipheriv('aes-256-gcm',this.key,iv);return Buffer.concat([iv,cipher.update(value,'utf8'),cipher.final(),cipher.getAuthTag()]).toString('base64');}
	private decrypt(value:string){const data=Buffer.from(value,'base64'),cipher=createDecipheriv('aes-256-gcm',this.key,data.subarray(0,12));cipher.setAuthTag(data.subarray(-16));return Buffer.concat([cipher.update(data.subarray(12,-16)),cipher.final()]).toString('utf8');}
	account(id:string):Account|null{if(!this.db.prepare('SELECT id FROM users WHERE id=?').get(id))return null;return{id,identities:this.db.prepare('SELECT provider,email FROM identities WHERE user_id=? ORDER BY provider').all(id) as Account['identities']};}
	login(identity:Identity,linkTo?:string):Account{return this.transaction(()=>{
		const existing=this.db.prepare('SELECT user_id FROM identities WHERE provider=? AND subject=?').get(identity.provider,identity.subject) as any;
		if(linkTo&&existing&&existing.user_id!==linkTo)throw new Error('This login is already linked to another account.');
		const id=linkTo||existing?.user_id||randomUUID();
		if(linkTo&&!this.account(linkTo))throw new Error('Account no longer exists');
		this.db.prepare('INSERT OR IGNORE INTO users VALUES(?,?)').run(id,now());
		const linked=this.db.prepare('SELECT subject FROM identities WHERE user_id=? AND provider=?').get(id,identity.provider) as any;
		if(linked&&linked.subject!==identity.subject)throw new Error('This account already has a different login for that provider.');
		this.db.prepare('INSERT INTO identities VALUES(?,?,?,?) ON CONFLICT(provider,subject) DO UPDATE SET email=COALESCE(excluded.email,identities.email)').run(identity.provider,identity.subject,id,identity.email||null);
		if(identity.grant)this.db.prepare('INSERT INTO grants VALUES(?,?,?,?,?) ON CONFLICT(provider,subject,client_id) DO UPDATE SET grant=excluded.grant').run(identity.provider,identity.subject,identity.clientID,id,this.encrypt(identity.grant));
		return this.account(id)!;
	});}
	ownsIdentity(id:string,identity:Identity){return !!this.db.prepare('SELECT 1 FROM identities WHERE user_id=? AND provider=? AND subject=?').get(id,identity.provider,identity.subject);}
	createSession(userID:string){const token=secret();this.db.prepare('DELETE FROM sessions WHERE expires<=?').run(now());this.db.prepare('INSERT INTO sessions VALUES(?,?,?,?)').run(hash(token),userID,now()+30*86400,now());return token;}
	session(token:string){return this.sessionByHash(hash(token));}
	sessionByHash(sessionHash:string): (Account&{authenticatedAt:number})|null {const row=this.db.prepare('SELECT user_id,authenticated_at FROM sessions WHERE hash=? AND expires>?').get(sessionHash,now()) as any;const account=row&&this.account(row.user_id);return account?{...account,authenticatedAt:row.authenticated_at}:null;}
	logout(token:string){this.db.prepare('DELETE FROM sessions WHERE hash=?').run(hash(token));}
	reauthenticateHash(sessionHash:string){this.db.prepare('UPDATE sessions SET authenticated_at=? WHERE hash=?').run(now(),sessionHash);}
	challenge(value:Challenge){this.db.prepare('DELETE FROM challenges WHERE expires<=?').run(now());const id=secret();this.db.prepare('INSERT INTO challenges VALUES(?,?,?)').run(hash(id),now()+300,JSON.stringify(value));return id;}
	takeChallenge(id:string):Challenge|null{return this.transaction(()=>{const row=this.db.prepare('SELECT data FROM challenges WHERE hash=? AND expires>?').get(hash(id),now()) as any;this.db.prepare('DELETE FROM challenges WHERE hash=?').run(hash(id));return row?JSON.parse(row.data):null;});}
	settings(userID:string):SettingsRevision{const row=this.db.prepare('SELECT revision,data FROM settings WHERE user_id=?').get(userID) as any;return row?{revision:row.revision,settings:JSON.parse(row.data)}:{revision:0,settings:null};}
	putSettings(userID:string,revision:number,settings:Settings):SettingsRevision|null{return this.transaction(()=>{if(this.settings(userID).revision!==revision)return null;this.db.prepare('INSERT INTO settings VALUES(?,?,?) ON CONFLICT(user_id) DO UPDATE SET revision=excluded.revision,data=excluded.data').run(userID,revision+1,JSON.stringify(settings));return{revision:revision+1,settings};});}
	private queueGrants(id:string,provider?:string){const rows=this.db.prepare('SELECT provider,client_id,grant FROM grants WHERE user_id=?'+(provider?' AND provider=?':'')).all(...(provider?[id,provider]:[id])) as any[];for(const row of rows)this.db.prepare('INSERT INTO revocations VALUES(?,?,?,?)').run(randomUUID(),row.provider,row.client_id,row.grant);}
	unlink(id:string,provider:ProviderName){this.transaction(()=>{if((this.account(id)?.identities.length||0)<2)throw new Error('Keep at least one login method.');this.queueGrants(id,provider);this.db.prepare('DELETE FROM grants WHERE user_id=? AND provider=?').run(id,provider);this.db.prepare('DELETE FROM identities WHERE user_id=? AND provider=?').run(id,provider);this.db.prepare('DELETE FROM sessions WHERE user_id=?').run(id);});}
	deleteAccount(id:string){this.transaction(()=>{this.queueGrants(id);this.db.prepare('INSERT OR IGNORE INTO account_deletions VALUES(?,?)').run(id,now());this.db.prepare('DELETE FROM users WHERE id=?').run(id);});}
	revocations():{id:string;provider:ProviderName;clientID:string;grant:string}[]{return(this.db.prepare('SELECT * FROM revocations LIMIT 20').all() as any[]).map(r=>({id:r.id,provider:r.provider,clientID:r.client_id,grant:this.decrypt(r.grant)}));}
	finishRevocation(id:string){this.db.prepare('DELETE FROM revocations WHERE id=?').run(id);}
}
