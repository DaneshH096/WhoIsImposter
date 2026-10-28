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

test('invite links preserve the room code and copy a join URL', async ({ page, context }) => {
  await page.goto('/?room=ABC234');
  await expect(page.getByText(/you’re invited to room ABC234/i)).toBeVisible();
  await expect(page.getByRole('textbox',{name:'Room code'})).toHaveValue('ABC234');
  await context.grantPermissions(['clipboard-read','clipboard-write']);
  await page.getByRole('button',{name:/peek at the lobby design/i}).click();
  await page.getByRole('button',{name:'Copy invite link'}).click();
  await expect(page.getByRole('button',{name:'Copy invite link'})).toContainText('Link copied!');
  const copied=await page.evaluate(()=>navigator.clipboard.readText());
  expect(new URL(copied).searchParams.get('room')).toBe('PARTY!');
});

test('voice clue transcript is reviewed in the clue field before submission', async ({ page }) => {
  await page.addInitScript({content:`class MockRecognition { constructor(){ this.lang=''; this.continuous=false; this.interimResults=false; this.maxAlternatives=1; this.onstart=null; this.onend=null; this.onresult=null; this.onerror=null; } start(){ window.__recognition=this; this.onstart?.(); } stop(){ this.onend?.(); } abort(){ this.onend?.(); } } window.SpeechRecognition=MockRecognition;`});
  await page.goto('/');
  await page.getByRole('button',{name:/peek at the lobby design/i}).click();
  await page.getByRole('button',{name:/start round/i}).click();
  await page.getByRole('button',{name:/preview: advance phase/i}).click();
  await expect(page.getByRole('textbox',{name:'Your clue'})).toBeVisible();
  await page.getByRole('button',{name:'Start voice input'}).click();
  await page.evaluate(()=>{
    const recognition=Reflect.get(window,'__recognition');
    recognition.onresult({results:[[{transcript:'Definitely cheesy'}]]});
    recognition.onend();
  });
  await expect(page.getByRole('textbox',{name:'Your clue'})).toHaveValue('Definitely cheesy');
  await expect(page.getByText(/stores only the text you submit/i)).toBeVisible();
});

