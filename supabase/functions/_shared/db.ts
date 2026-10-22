// Narrow database port used by domain code. A supabase-js client satisfies it; tests use fakes.
import { type DbError, fromDbError } from "./errors.ts";

export interface RpcResult {
  data: unknown;
  error: DbError | null;
}

export interface RpcClient {
  // deno-lint-ignore no-explicit-any
  rpc(fn: string, args?: Record<string, unknown>): PromiseLike<any>;
}

/** Calls a Postgres function and returns its data, mapping errors to ApiError. */
export async function callRpc<T>(db: RpcClient, fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = (await db.rpc(fn, args)) as RpcResult;
  if (error) throw fromDbError(error);
  return data as T;
}
