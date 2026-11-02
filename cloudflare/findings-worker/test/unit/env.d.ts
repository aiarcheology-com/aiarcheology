import type { D1Migration } from '@cloudflare/vitest-plugin';
import type { Env } from '../../src/env';

declare global {
  namespace Cloudflare {
    interface Env extends AppEnv {
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}

type AppEnv = Env;

export {};
