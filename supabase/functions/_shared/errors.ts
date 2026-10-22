// API error model shared by every function.
//
// Responses always use the shape `{ "error": { "code": string, "message": string, "details"?: unknown } }`.

export type ErrorCode =
  | "unauthorized"
  | "forbidden"
  | "not_found"
  | "invalid_request"
  | "conflict"
  | "internal";

const STATUS: Record<ErrorCode, number> = {
  unauthorized: 401,
  forbidden: 403,
  not_found: 404,
  invalid_request: 400,
  conflict: 409,
  internal: 500,
};

export class ApiError extends Error {
  readonly code: ErrorCode;
  readonly status: number;
  readonly details?: unknown;

  constructor(code: ErrorCode, message: string, details?: unknown) {
    super(message);
    this.name = "ApiError";
    this.code = code;
    this.status = STATUS[code];
    this.details = details;
  }
}

/** Minimal shape of a PostgREST / Postgres error returned by supabase-js. */
export interface DbError {
  code?: string;
  message: string;
  details?: string | null;
  hint?: string | null;
}

/** Maps a Postgres SQLSTATE (as returned through PostgREST) to an ApiError. */
export function fromDbError(error: DbError): ApiError {
  const code = error.code ?? "";
  switch (code) {
    case "P0002": // no_data_found
    case "PGRST116":
      return new ApiError("not_found", error.message);
    case "42501": // insufficient_privilege
      return new ApiError("forbidden", error.message);
    case "55000": // object_not_in_prerequisite_state
    case "23505": // unique_violation
      return new ApiError("conflict", error.message);
    case "22023": // invalid_parameter_value
    case "22P02": // invalid_text_representation
    case "22007": // invalid_datetime_format
    case "22008":
    case "23502":
    case "23503":
    case "23514":
      return new ApiError("invalid_request", error.message);
    case "PGRST301":
    case "PGRST302":
      return new ApiError("unauthorized", error.message);
    default:
      return new ApiError("internal", "Database error", { code, message: error.message });
  }
}

export function errorBody(error: ApiError): Record<string, unknown> {
  const body: Record<string, unknown> = { code: error.code, message: error.message };
  if (error.details !== undefined) body.details = error.details;
  return { error: body };
}

export function jsonError(error: ApiError): Response {
  return Response.json(errorBody(error), { status: error.status });
}
