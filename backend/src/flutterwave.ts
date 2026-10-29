import { config } from './config';
import { HttpError } from './errors';

const FLW_API = 'https://api.flutterwave.com/v3';

export async function flwRequest<T>(
  path: string,
  options: { method?: 'GET' | 'POST'; body?: unknown } = {}
): Promise<T> {
  if (!config.FLW_SECRET_KEY) {
    throw new HttpError(503, 'Flutterwave integration is not configured');
  }

  const response = await fetch(`${FLW_API}${path}`, {
    method: options.method ?? 'GET',
    headers: {
      Authorization: `Bearer ${config.FLW_SECRET_KEY}`,
      'Content-Type': 'application/json'
    },
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
    signal: AbortSignal.timeout(15_000)
  });
  const body: unknown = await response.json();
  if (!response.ok) throw new Error(`Flutterwave API returned HTTP ${response.status}`);
  return body as T;
}
