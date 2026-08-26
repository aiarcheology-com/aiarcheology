import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-pool-workers';
import { defineConfig } from 'vitest/config';

const migrations = await readD1Migrations(new URL('./migrations', import.meta.url).pathname);

export default defineConfig({
  plugins: [
    cloudflareTest({
      // Bindings are simulated locally by Miniflare. This must stay false: `true` would point the
      // suite's R2 and D1 at the real staging resources, and a test suite that can reach real
      // storage is one configuration mistake away from reaching the wrong real storage.
      remoteBindings: false,
      wrangler: { configPath: './wrangler.jsonc', environment: 'staging' },
      miniflare: {
        // The staging vars are overridden here so the caps are small enough for a test to actually
        // reach, and so token verification resolves a local key set rather than the real Clerk
        // instance.
        bindings: {
          TEST_MIGRATIONS: migrations,
          CLERK_ISSUER: 'https://issuer.test',
          CLERK_JWKS_URL: 'https://issuer.test/.well-known/jwks.json',
          USER_BYTE_LIMIT: 4096,
          GLOBAL_BYTE_CEILING: 1000000,
          IMAGE_BYTE_LIMIT: 2048,
          META_BYTE_LIMIT: 1024,
          CLERK_WEBHOOK_SECRET: 'whsec_dGVzdC1zZWNyZXQtZm9yLXVuaXQtdGVzdHM=',
        },
      },
    }),
  ],
  test: {
    include: ['test/unit/**/*.test.ts'],
    setupFiles: ['./test/unit/setup.ts'],
  },
});
