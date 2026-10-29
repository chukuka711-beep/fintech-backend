import { NextFunction, Request, Response } from 'express';
import jwt from 'jsonwebtoken';
import { config } from './config';
import { HttpError } from './errors';

declare global {
  namespace Express {
    interface Request {
      userId?: string;
    }
  }
}

export function authenticate(req: Request, _res: Response, next: NextFunction): void {
  const token = req.header('authorization')?.match(/^Bearer ([^\s]+)$/)?.[1];
  if (!token) return next(new HttpError(401, 'Authentication required'));
  try {
    const payload = jwt.verify(token, config.JWT_SECRET);
    if (typeof payload === 'string' || payload.type !== 'access' || typeof payload.sub !== 'string') {
      throw new Error('Invalid access token');
    }
    req.userId = payload.sub;
    next();
  } catch {
    next(new HttpError(401, 'Invalid or expired access token'));
  }
}

export function asyncRoute(
  handler: (req: Request, res: Response) => Promise<unknown>
) {
  return (req: Request, res: Response, next: NextFunction): void => {
    void handler(req, res).catch(next);
  };
}

export function errorHandler(
  error: unknown,
  _req: Request,
  res: Response,
  _next: NextFunction
): void {
  if (error instanceof HttpError) {
    res.status(error.status).json({ error: error.message });
    return;
  }
  console.error('Request failed', error instanceof Error ? error.message : 'Unknown error');
  res.status(500).json({ error: 'Internal server error' });
}
