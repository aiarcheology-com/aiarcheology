export interface Env {
  FINDINGS: R2Bucket;
  DB: D1Database;
  CLERK_ISSUER: string;
  CLERK_JWKS_URL: string;
  USER_BYTE_LIMIT: number;
  GLOBAL_BYTE_CEILING: number;
  IMAGE_BYTE_LIMIT: number;
  META_BYTE_LIMIT: number;
}
