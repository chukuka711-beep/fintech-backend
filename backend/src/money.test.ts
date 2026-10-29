import { describe, expect, it } from 'vitest';
import { koboToNairaDecimal, parseKobo } from './money';

describe('NGN money conversion', () => {
  it('parses decimal NGN into integer kobo without floating-point arithmetic', () => {
    expect(parseKobo('100')).toBe(10_000n);
    expect(parseKobo('0.01')).toBe(1n);
    expect(parseKobo('12.5')).toBe(1_250n);
  });

  it('rejects invalid precision and non-positive amounts', () => {
    expect(() => parseKobo('1.001')).toThrow();
    expect(() => parseKobo('0')).toThrow();
    expect(() => parseKobo('-1')).toThrow();
  });

  it('serializes kobo as an exact two-decimal NGN string', () => {
    expect(koboToNairaDecimal(10001n)).toBe('100.01');
    expect(koboToNairaDecimal(1n)).toBe('0.01');
  });
});
