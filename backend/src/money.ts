import { HttpError } from './errors';

export function parseKobo(value: unknown): bigint {
  if (typeof value !== 'string' && typeof value !== 'number') {
    throw new HttpError(400, 'Amount must be a decimal NGN amount');
  }
  const input = String(value);
  if (!/^(0|[1-9]\d*)(\.\d{1,2})?$/.test(input)) {
    throw new HttpError(400, 'Amount must have at most two decimal places');
  }
  const [naira, fraction = ''] = input.split('.');
  const result = BigInt(naira) * 100n + BigInt(fraction.padEnd(2, '0'));
  if (result <= 0n) throw new HttpError(400, 'Amount must be greater than zero');
  return result;
}

export function koboToNairaDecimal(amount: bigint): string {
  return `${amount / 100n}.${(amount % 100n).toString().padStart(2, '0')}`;
}
