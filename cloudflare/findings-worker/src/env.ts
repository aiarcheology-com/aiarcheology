export interface Env {
  FINDINGS: R2Bucket;
  DB: D1Database;
  CLERK_ISSUER: string;
  CLERK_JWKS_URL: string;
  USER_BYTE_LIMIT: number;
  GLOBAL_BYTE_CEILING: number;
  IMAGE_BYTE_LIMIT: number;
  META_BYTE_LIMIT: number;
  /// svix signing secret for Clerk's webhooks. Absent in an environment that has none configured,
  /// where the webhook route refuses rather than trusting anything.
  CLERK_WEBHOOK_SECRET?: string;
}
