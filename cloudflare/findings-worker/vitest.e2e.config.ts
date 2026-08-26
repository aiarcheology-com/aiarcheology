import { defineConfig } from 'vitest/config';

/// The staging end-to-end suite. Deliberately NOT part of `npm test`: it needs credentials and a
/// deployed Worker, and it writes to a real bucket.
export default defineConfig({
  test: {
    include: ['test/e2e/**/*.test.ts'],
    // Real network round trips against a deployed Worker, and they must run in order.
    testTimeout: 30_000,
    hookTimeout: 60_000,
    fileParallelism: false,
    sequence: { concurrent: false },
  },
});
