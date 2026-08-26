import { applyD1Migrations, env } from 'cloudflare:test';
import { beforeAll } from 'vitest';
import { installTestKeySet } from './helpers';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  await installTestKeySet();
});
