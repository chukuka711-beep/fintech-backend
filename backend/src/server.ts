import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import { config } from './config';
import { apiRouter } from './api';
import { errorHandler } from './middleware';
import { pool } from './db';
import { reconcilePendingPurchases } from './reconcile';

const app = express();
app.use(helmet());
app.use(cors({
  origin: (origin, callback) => {
    const isLocalDevelopmentOrigin = process.env.NODE_ENV !== 'production' &&
      /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin ?? '');
    callback(null, !origin || origin === config.APP_BASE_URL || isLocalDevelopmentOrigin);
  }
}));
app.use(express.json({ limit: '128kb' }));
app.use(rateLimit({ windowMs: 60_000, limit: 120, standardHeaders: true, legacyHeaders: false }));
app.get('/health', (_req, res) => res.json({ status: 'ok' }));
app.use(apiRouter);
app.use(errorHandler);

const server = app.listen(Number(process.env.PORT ?? 3000), () => {
  console.info(`API listening on port ${Number(process.env.PORT ?? 3000)}`);
  const reconciliation = setInterval(() => {
    void reconcilePendingPurchases().catch(() => {
      console.error('Purchase reconciliation job failed');
    });
  }, 30_000);
  reconciliation.unref();
});

async function shutdown() {
  server.close();
  await pool.end();
}

process.once('SIGINT', () => void shutdown());
process.once('SIGTERM', () => void shutdown());
