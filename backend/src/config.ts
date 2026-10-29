import 'dotenv/config';
import { z } from 'zod';

const schema = z.object({
  DATABASE_URL: z.string().url(),
  DIRECT_URL: z.string().url(),
  JWT_SECRET: z.string().min(32),
  FLW_SECRET_KEY: z.string().default(''),
  FLW_PUBLIC_KEY: z.string().optional(),
  FLW_WEBHOOK_SECRET: z.string().min(1),
  PORT: z.coerce.number().int().positive().default(3000),
  APP_BASE_URL: z.string().url(),
  OTP_TTL_MINUTES: z.coerce.number().int().positive().default(10),
  SMTP_URL: z.string().optional(),
  SMTP_FROM: z.string().email().optional(),
  DEV_OTP_LOGGING: z.enum(['true', 'false']).default('false').transform(value => value === 'true'),
  PROVIDER_FLOAT_MIN_KOBO: z.coerce.bigint().nonnegative().default(50_000_000n),
  ADMIN_API_KEY: z.string().optional()
});

export const config = schema.parse(process.env);
