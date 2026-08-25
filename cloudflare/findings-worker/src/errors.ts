/// The wire error contract.
///
/// `retryable` is not a hint: the Phase 3 outbox splits on exactly this field, parking an item on a
/// terminal error and backing off on a retryable one. Adding a code without deciding its
/// retryability would leave the client guessing.
export type ErrorCode =
  | 'unauthorized'
  | 'not_found'
  | 'bad_request'
  | 'payload_too_large'
  | 'quota_exceeded'
  | 'global_capacity'
  | 'stale'
  | 'config_error'
  | 'internal';

const STATUS: Record<ErrorCode, number> = {
  unauthorized: 401,
  not_found: 404,
  bad_request: 400,
  payload_too_large: 413,
  quota_exceeded: 507,
  global_capacity: 507,
  stale: 409,
  config_error: 503,
  internal: 500,
};

/// `unauthorized` is retryable because the cure is a token refresh, not parking the finding -- an
/// expired token is the normal state of a device that has been offline for an hour. `quota_exceeded`
/// is terminal: retrying cannot make room, only the user pruning findings can.
const RETRYABLE: Record<ErrorCode, boolean> = {
  unauthorized: true,
  not_found: false,
  bad_request: false,
  payload_too_large: false,
  quota_exceeded: false,
  global_capacity: false,
  stale: false,
  config_error: true,
  internal: true,
};

export class ApiError extends Error {
  readonly code: ErrorCode;
  readonly detail: Record<string, unknown>;

  constructor(code: ErrorCode, message: string, detail: Record<string, unknown> = {}) {
    super(message);
    this.code = code;
    this.detail = detail;
  }

  get status(): number {
    return STATUS[this.code];
  }

  get retryable(): boolean {
    return RETRYABLE[this.code];
  }
}

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'x-content-type-options': 'nosniff', ...headers },
  });
}

export function errorResponse(error: unknown): Response {
  const api =
    error instanceof ApiError ? error : new ApiError('internal', 'Unexpected error handling the request.');
  if (!(error instanceof ApiError)) {
    console.error('unhandled', error);
  }
  return json(
    { error: { code: api.code, message: api.message, retryable: api.retryable, ...api.detail } },
    api.status,
  );
}
