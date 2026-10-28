import { test, expect } from '@playwright/test';

test('landing page is responsive and explains the game', async ({ page }) => {
  await page.setViewportSize({width:390,height:844});
  await page.goto('/');
  await expect(page.getByRole('heading',{name:/someone here is lying/i})).toBeVisible();
  await expect(page.getByText('4–8 players')).toBeVisible();
  await expect(page.getByPlaceholder('e.g. suspicious potato')).toBeVisible();
  const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>window.innerWidth);
  expect(overflow).toBe(false);
});

test('lobby preview renders room code, roster, and host controls', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('button',{name:/peek at the lobby design/i}).click();
  await expect(page.getByText('ROOM CODE')).toBeVisible();
  await expect(page.getByRole('heading',{name:'The Suspicious Club'})).toBeVisible();
  await expect(page.getByText('5 players')).toBeVisible();
  await expect(page.getByRole('button',{name:/start round/i})).toBeVisible();
});
