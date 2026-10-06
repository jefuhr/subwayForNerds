import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { decodeNerds, defaults, type Settings } from '../../shared/settings';
const fixture=readFileSync(new URL('../fixtures/settings.nerds',import.meta.url));
const upload={name:'settings.nerds',mimeType:'application/vnd.subwaysfornerds.settings+json',buffer:fixture};

test('settings files preview, cancel, replace and round trip widget preferences',async({page})=>{
	await page.goto('./?station=602');await page.getByRole('button',{name:'Open settings'}).click();
	await page.getByLabel('Import settings file').setInputFiles(upload);
	await expect(page.getByRole('heading',{name:'Replace settings?'})).toBeVisible();
	await page.getByRole('button',{name:'Cancel import'}).click();
	await expect(page.locator('html')).toHaveAttribute('data-theme','subway');
	await page.getByLabel('Import settings file').setInputFiles(upload);
	await page.getByRole('button',{name:'Replace settings',exact:true}).click();
	await expect(page.locator('html')).toHaveAttribute('data-theme','hello-kitty');
	const downloadPromise=page.waitForEvent('download');await page.getByRole('button',{name:'Export settings'}).click();
	const download=await downloadPromise;expect(download.suggestedFilename()).toMatch(/\.nerds$/);
	const saved=decodeNerds(readFileSync((await download.path())!,'utf8'));
	expect(saved.settings).toEqual(decodeNerds(fixture.toString()).settings);
	await page.reload();await expect(page.locator('html')).toHaveAttribute('data-theme','hello-kitty');
	await page.getByRole('button',{name:'Open settings'}).click();
	await page.getByLabel('Import settings file').setInputFiles({...upload,buffer:Buffer.from('{"version":2}')});
	await expect(page.getByRole('alert')).toContainText('not a valid');
	await expect(page.locator('html')).toHaveAttribute('data-theme','hello-kitty');
});
test('account sync preserves offline edits and requires explicit conflict resolution',async({page,context})=>{
	let remote:Settings=defaults();let revision=1;
	await context.route('**/api/v1/auth/config',route=>route.fulfill({json:{enabled:true}}));
	await context.route('**/api/v1/account',route=>route.fulfill({json:{account:{id:'test-account',identities:[{provider:'apple',email:'person@example.test'}]},csrf:'csrf'}}));
	await context.route('**/api/v1/account/settings',async route=>{
		if(route.request().method()==='PUT'){
			if(route.request().headers()['if-match']!=='"'+revision+'"'){await route.fulfill({status:412,json:{revision,settings:remote}});return;}
			remote=route.request().postDataJSON();revision++;
		}
		await route.fulfill({json:{revision,settings:remote}});
	});
	await page.goto('./?station=602');await page.getByRole('button',{name:'Open settings'}).click();
	await expect(page.getByRole('status')).toHaveText('Settings synced');
	// WebKit's network emulation also blocks Playwright's file injection. Select locally first.
	await page.getByLabel('Import settings file').setInputFiles(upload);
	await expect(page.getByRole('heading',{name:'Replace settings?'})).toBeVisible();
	await context.setOffline(true);
	await page.getByRole('button',{name:'Replace settings',exact:true}).click();
	await expect(page.locator('html')).toHaveAttribute('data-theme','hello-kitty');
	remote={...remote,theme:'hacker',favorites:['617']};revision++;
	await context.setOffline(false);
	await expect(page.getByRole('heading',{name:'Choose which changes to keep'})).toBeVisible();
	await page.getByRole('combobox').selectOption('local');await page.getByRole('button',{name:'Save choices'}).click();
	await expect(page.getByRole('status').filter({hasText:'Settings synced'})).toBeVisible();
	expect(remote.theme).toBe('hello-kitty');expect(remote.favorites).toEqual(['617','602','future:station']);
	expect(remote.widgets.display.trainsPerDirection).toBe(4);
});

test('privacy remains a standalone document under the installed service worker',async({page})=>{
	await page.goto('./');await page.evaluate(async()=>{await navigator.serviceWorker.ready;});
	await page.reload();await page.goto('./privacy.html');
	await expect(page.getByRole('heading',{name:'Privacy',exact:true})).toBeVisible();
	await expect(page.getByRole('heading',{name:'Optional accounts'})).toBeVisible();
});

test('an account switch cannot upload an in-flight edit into the next account',async({page,context})=>{
	let user='one';const saved:Record<string,Settings>={one:defaults(),two:{...defaults(),theme:'hacker'}};
	let hold=false,started=false,release:()=>void=()=>{};const gate=new Promise<void>(resolve=>{release=resolve;});
	const writes:string[]=[];
	await context.route('**/api/v1/auth/config',route=>route.fulfill({json:{enabled:true}}));
	await context.route('**/api/v1/account',route=>route.fulfill({json:{account:{id:user,identities:[{provider:'apple',email:user+'@example.test'}]},csrf:user}}));
	await context.route('**/api/v1/account/settings',async route=>{
		const owner=user;
		if(hold&&owner==='one'&&route.request().method()==='GET'){started=true;await gate;}
		if(route.request().method()==='PUT'){writes.push(owner);saved[owner]=route.request().postDataJSON();}
		await route.fulfill({json:{revision:1,settings:saved[owner]}});
	});
	await page.goto('./');await page.getByRole('button',{name:'Open settings'}).click();await expect(page.getByRole('status')).toHaveText('Settings synced');
	hold=true;
	await page.getByLabel('Import settings file').setInputFiles(upload);await page.getByRole('button',{name:'Replace settings',exact:true}).click();
	await page.getByRole('button',{name:'Sync now'}).click();await expect.poll(()=>started).toBe(true);
	user='two';await page.evaluate(()=>window.dispatchEvent(new Event('online')));
	await expect(page.getByText('Apple · two@example.test')).toBeVisible();release();
	await expect(page.getByRole('heading',{name:'Choose settings to start syncing'})).toBeVisible();
	expect(writes).not.toContain('two');expect(saved.two.theme).toBe('hacker');
	await page.getByRole('button',{name:'Use account settings'}).click();await expect(page.locator('html')).toHaveAttribute('data-theme','hacker');
});

test('a failed import save leaves the previous preferences intact',async({page})=>{
	await page.goto('./');await page.getByRole('button',{name:'Open settings'}).click();
	await page.getByLabel('Import settings file').setInputFiles(upload);
	await page.evaluate(()=>{const original=Storage.prototype.setItem;Storage.prototype.setItem=function(key,value){if(key==='sfn:settings:v1')throw new DOMException('Full','QuotaExceededError');return original.call(this,key,value);};});
	await page.getByRole('button',{name:'Replace settings',exact:true}).click();
	await expect(page.getByRole('alert')).toContainText('could not be saved');
	await expect(page.locator('html')).toHaveAttribute('data-theme','subway');
	await page.reload();await expect(page.locator('html')).toHaveAttribute('data-theme','subway');
});
