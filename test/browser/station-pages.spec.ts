import { test, expect, type Page } from '@playwright/test';

async function seed(page: Page, favorites = ['602', '617', '611']) {
  await page.addInitScript(({ favorites }) => {
    localStorage.setItem('sfn:favorites', JSON.stringify(favorites));
    localStorage.setItem('sfn:station', JSON.stringify('602'));
    navigator.geolocation.getCurrentPosition = (_ok, fail) => fail?.({ code: 1 } as GeolocationPositionError);
  }, { favorites });
}
const active = (page: Page) => page.locator('.active-page');
async function swipe(page: Page, dx: number, dy = 0, selector = '.active-page .station-heading') {
  await page.locator(selector).evaluate((el, { dx, dy }) => {
    const rect = el.getBoundingClientRect(), x = rect.left + rect.width / 2, y = rect.top + 30;
    const touch = (clientX: number, clientY: number) => new Touch({ identifier: 1, target: el, clientX, clientY });
    el.dispatchEvent(new TouchEvent('touchstart', { bubbles: true, touches: [touch(x, y)] }));
    el.dispatchEvent(new TouchEvent('touchmove', { bubbles: true, cancelable: true, touches: [touch(x + dx, y + dy)] }));
    el.dispatchEvent(new TouchEvent('touchend', { bubbles: true, changedTouches: [touch(x + dx, y + dy)] }));
  }, { dx, dy });
}

test('favorite pages navigate with controls, keyboard, history and per-station filters', async ({ page }) => {
  await seed(page);
  await page.goto('./?station=602');
  await expect(active(page).locator('h1')).toHaveText('14 St-Union Sq');
  await expect(page.getByRole('button', { name: 'Previous station' })).toBeDisabled();
  await active(page).getByRole('button', { name: 'Northbound', exact: true }).click();
  await active(page).getByRole('button', { name: 'View: Track', exact: true }).click();
  await page.getByRole('menuitemradio', { name: 'By direction · all platforms', exact: true }).click();
  await page.getByRole('button', { name: 'Next station', exact: true }).click();
  await expect(page).toHaveURL(/station=617/);
  await expect(active(page).getByRole('button', { name: 'View: Track', exact: true })).toBeVisible();
  await expect(active(page).getByRole('button', { name: 'All directions', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(page.getByRole('navigation', { name: 'Station pages' })).toBeFocused();
  await page.keyboard.press('ArrowRight');
  await expect(page).toHaveURL(/station=611/);
  await expect(page.getByRole('button', { name: 'Next station', exact: true })).toBeDisabled();
  await page.goBack(); await expect(page).toHaveURL(/station=617/);
  await page.goBack(); await expect(page).toHaveURL(/station=602/);
  await expect(active(page).getByRole('button', { name: 'Northbound', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(active(page).getByRole('button', { name: 'View: Direction', exact: true })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

test('temporary station remains available and favorite edits keep current station selected', async ({ page }) => {
  await seed(page, ['617', '611']);
  await page.goto('./?station=602');
  await expect(page.locator('.station-page-count')).toHaveText('1 / 3');
  await page.getByRole('button', { name: 'Next station', exact: true }).click();
  await expect(page).toHaveURL(/station=617/);
  await page.getByRole('button', { name: 'Previous station', exact: true }).click();
  await expect(page).toHaveURL(/station=602/);
  await active(page).getByRole('button', { name: 'Favorite this station', exact: true }).click();
  await expect(page.locator('.station-page-count')).toHaveText('3 / 3');
  await active(page).getByRole('button', { name: 'Remove favorite station', exact: true }).click();
  await expect(page.locator('.station-page-count')).toHaveText('1 / 3');
  await expect(active(page).locator('h1')).toHaveText('14 St-Union Sq');
});

test('touch swipes change pages without hijacking vertical or filter scrolling', async ({ page, isMobile }) => {
  test.skip(!isMobile);
  await seed(page); await page.goto('./?station=602');
  await expect(page.locator('.station-page-count')).toHaveText('1 / 3');
  await swipe(page, 120); await expect(page).toHaveURL(/station=602/);
  await swipe(page, -20, 120); await expect(page).toHaveURL(/station=602/);
  await swipe(page, -130, 0, '.active-page .route-filters'); await expect(page).toHaveURL(/station=602/);
  await swipe(page, -130); await expect(page).toHaveURL(/station=617/);
  await swipe(page, 130); await expect(page).toHaveURL(/station=602/);
  await expect(page.locator('dialog')).toHaveCount(0);
});

test('location sorts favorites and opens closest unless a station is explicit', async ({ page }) => {
  await seed(page);
  await page.addInitScript(() => {
    navigator.geolocation.getCurrentPosition = ok => ok({ coords: { latitude: 40.7527, longitude: -73.9772 }, timestamp: Date.now() } as GeolocationPosition);
  });
  await page.goto('./');
  await expect(page).toHaveURL(/station=611/);
  await expect(page.locator('.station-page-count')).toHaveText('1 / 3');
  await page.goto('./?station=602');
  await expect(page.locator('.station-page-count')).toHaveText('2 / 3');
  await expect(page).toHaveURL(/station=602/);
});

test('late location does not change the selected station or saved-order pages after interaction', async ({ page }) => {
  await seed(page);
  await page.addInitScript(() => {
    navigator.geolocation.getCurrentPosition = ok => { (window as any).resolveLocation = () => ok({ coords: { latitude: 40.7527, longitude: -73.9772 }, timestamp: Date.now() } as GeolocationPosition); };
  });
  await page.goto('./');
  await expect(page.locator('.station-page-count')).toHaveText('1 / 3');
  await page.getByRole('button', { name: 'Next station', exact: true }).click();
  await expect(page).toHaveURL(/station=617/);
  await page.evaluate(() => (window as any).resolveLocation());
  await expect(page).toHaveURL(/station=617/);
  await expect(page.locator('.station-page-count')).toHaveText('2 / 3');
});

test('zero or one page hides controls; many favorites and reduced motion stay usable', async ({ page }) => {
  await seed(page, []); await page.goto('./?station=602');
  await expect(active(page).locator('h1')).toBeVisible();
  await expect(page.getByRole('navigation', { name: 'Station pages' })).toHaveCount(0);
  await active(page).getByRole('button', { name: 'Favorite this station', exact: true }).click();
  await expect(page.getByRole('navigation', { name: 'Station pages' })).toHaveCount(0);
  const ids = await page.evaluate(() => JSON.parse(localStorage.getItem('sfn:stations')!).slice(0, 30).map((s: { id: string }) => s.id));
  await page.addInitScript(ids => {
    const saved = JSON.parse(localStorage.getItem('sfn:settings:v1')!); saved.settings.favorites = ids;
    localStorage.setItem('sfn:settings:v1', JSON.stringify(saved));
  }, ids);
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto(`./?station=${ids[0]}`);
  await expect(page.locator('.station-page-dots button')).toHaveCount(30);
  await page.getByRole('button', { name: 'Next station', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`station=${ids[1]}`));
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

test('cached favorites remain swipeable offline and a root visit restores its original station with Back', async ({ page, context }) => {
  await seed(page); await page.goto('./');
  await expect(active(page).locator('h1')).toHaveText('14 St-Union Sq');
  await expect.poll(() => page.evaluate(() => ['602', '617', '611'].every(id => !!localStorage.getItem('sfn:board:' + id)))).toBe(true);
  await context.setOffline(true);
  await page.getByRole('button', { name: 'Next station', exact: true }).click();
  await expect(page).toHaveURL(/station=617/);
  await expect(active(page).locator('.status-pill')).toHaveText('CACHED BOARD');
  await expect(active(page).locator('.train-row').first()).toBeVisible();
  await page.goBack();
  await expect(active(page).locator('h1')).toHaveText('14 St-Union Sq');
  await expect(page.locator('.station-page-count')).toHaveText('1 / 3');
});

test('native touch gestures preserve vertical scrolling and train taps, and do not navigate behind dialogs', async ({ page, context, isMobile, browserName }) => {
  test.skip(!isMobile || browserName !== 'chromium');
  await seed(page); await page.goto('./?station=602');
  const row = active(page).locator('.train-row').first();
  await expect(row).toBeVisible();
  const session = await context.newCDPSession(page);
  async function drag(x: number, y: number, dx: number, dy: number) {
    await session.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y }] });
    for (let i = 1; i <= 8; i++) await session.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: x + dx * i / 8, y: y + dy * i / 8 }] });
    await session.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  }
  await drag(250, 100, -150, 0);
  await expect(page).toHaveURL(/station=617/);
  await expect(page.locator('dialog')).toHaveCount(0);
  await drag(180, 600, 0, -220);
  await expect.poll(() => page.evaluate(() => scrollY)).toBeGreaterThan(50);
  await expect(page).toHaveURL(/station=617/);
  await page.evaluate(() => window.scrollTo(0, 0));
  await active(page).locator('.train-row').first().tap();
  await expect(page.locator('dialog')).toHaveCount(1);
  await swipe(page, -150);
  await expect(page).toHaveURL(/station=617/);
  await page.getByRole('button', { name: 'Close panel', exact: true }).tap();
  await expect(page.locator('dialog')).toHaveCount(0);
});
