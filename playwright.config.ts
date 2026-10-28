import { defineConfig, devices } from '@playwright/test';
export default defineConfig({ testDir:'./tests', globalSetup:'./tests/global-setup.mjs', use:{ baseURL:'http://127.0.0.1:4173', ...devices['Desktop Chrome'] } });
