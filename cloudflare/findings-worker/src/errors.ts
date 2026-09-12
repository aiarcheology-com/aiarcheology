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
  | 'account_deleting'
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
  account_deleting: 410,
  config_error: 503,
  internal: 500,
};

/// `error.code` is the normative key: a client's state machine should branch on it, and `retryable`
/// is the coarse summary derived from it.
///
/// `unauthorized` is retryable because the cure is a token refresh, not parking the finding -- an
/// expired token is the normal state of a device that has been offline for an hour.
/// `quota_exceeded` is terminal: retrying cannot make room, only the user pruning findings can.
/// `global_capacity` is NOT terminal, even though it looks like its neighbour: it is not this
/// user's condition and it clears when anyone prunes or the ceiling is raised. Parking on it would
/// strand every user's outbox permanently, and tell them to prune findings that were within their
/// quota all along.
const RETRYABLE: Record<ErrorCode, boolean> = {
  unauthorized: true,
  not_found: false,
  bad_request: false,
  payload_too_large: false,
  quota_exceeded: false,
  global_capacity: true,
  stale: false,
  // Terminal, and the only error where that is the point: the account is being erased, so there
  // will never be somewhere for this finding to go.
  account_deleting: false,
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
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'x-content-type-options': 'nosniff',
      // These bodies carry precise site coordinates and an author name, and the only thing
      // separating one user's from another's is a request header. Any cache that keys on URL alone
      // would hand one user the other's fieldwork.
      'cache-control': 'private, no-store',
      vary: 'Authorization',
      ...headers,
    },
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
    // Read back by the request log so a failure is countable by kind without the body being read.
    { 'x-error-code': api.code },
  );
}
