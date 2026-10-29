import { randomBytes, createHash, timingSafeEqual } from 'node:crypto';
import { Router, Request, Response } from 'express';
import rateLimit from 'express-rate-limit';
import argon2 from 'argon2';
import jwt from 'jsonwebtoken';
import nodemailer from 'nodemailer';
import { config } from './config';
import { pool, inTransaction } from './db';
import { HttpError } from './errors';
import { asyncRoute, authenticate } from './middleware';
import { flwRequest } from './flutterwave';
import { koboToNairaDecimal, parseKobo } from './money';
import { postLedgerEntry, setTransactionStatus } from './wallet';

const router = Router();
const authLimiter = rateLimit({ windowMs: 15 * 60_000, limit: 10, standardHeaders: true, legacyHeaders: false });
const purchaseLimiter = rateLimit({ windowMs: 60_000, limit: 5, standardHeaders: true, legacyHeaders: false });
const otpTransport = config.SMTP_URL ? nodemailer.createTransport(config.SMTP_URL) : null;
const hash = (value: string) => createHash('sha256').update(value).digest('hex');
const newReference = (prefix: string) => `${prefix}_${randomBytes(18).toString('hex')}`;

function requestString(value: unknown, label: string, max = 200): string {
  if (typeof value !== 'string' || value.trim().length === 0 || value.length > max) {
    throw new HttpError(400, `${label} is required`);
  }
  return value.trim();
}

async function sendOtp(email: string, code: string) {
  if (!otpTransport || !config.SMTP_FROM) {
    if (config.DEV_OTP_LOGGING && process.env.NODE_ENV !== 'production') {
      console.info(`Development OTP for ${email}: ${code}`);
      return;
    }
    throw new HttpError(503, 'Email delivery is not configured');
  }
  await otpTransport.sendMail({
    from: config.SMTP_FROM,
    to: email,
    subject: 'Your verification code',
    text: `Your verification code is ${code}. It expires soon.`
  });
}

router.post('/auth/register', authLimiter, asyncRoute(async (req, res) => {
  const email = requestString(req.body.email, 'Email').toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new HttpError(400, 'Invalid email address');
  const fullName = requestString(req.body.fullName, 'Full name');
  const password = requestString(req.body.password, 'Password', 200);
  const phone = requestString(req.body.phone, 'Phone', 20);
  if (!/^\+?[0-9]{7,15}$/.test(phone)) throw new HttpError(400, 'Invalid phone number');
  if (password.length < 10) throw new HttpError(400, 'Password must be at least 10 characters');
  const passwordHash = await argon2.hash(password);
  const code = randomBytes(4).readUInt32BE(0).toString().slice(0, 6).padStart(6, '0');
  const codeHash = await argon2.hash(code);
  await inTransaction(async client => {
    const user = await client.query<{ id: string }>(
      'INSERT INTO users(email, phone, full_name, password_hash) VALUES ($1, $2, $3, $4) RETURNING id',
      [email, phone, fullName, passwordHash]
    );
    await client.query('INSERT INTO wallets(user_id) VALUES ($1)', [user.rows[0].id]);
    await client.query('INSERT INTO notification_settings(user_id) VALUES ($1)', [user.rows[0].id]);
    await client.query(
      'INSERT INTO otp_challenges(email, code_hash, expires_at) VALUES ($1, $2, now() + ($3::int * interval \'1 minute\'))',
      [email, codeHash, config.OTP_TTL_MINUTES]
    );
  });
  try {
    await sendOtp(email, code);
  } catch (error) {
    await inTransaction(async client => {
      const user = await client.query<{ id: string }>('SELECT id FROM users WHERE email = $1', [email]);
      if (user.rowCount) {
        const id = user.rows[0].id;
        await client.query('DELETE FROM notification_settings WHERE user_id = $1', [id]);
        await client.query('DELETE FROM wallets WHERE user_id = $1', [id]);
        await client.query('DELETE FROM users WHERE id = $1', [id]);
      }
      await client.query('DELETE FROM otp_challenges WHERE email = $1', [email]);
    });
    throw error;
  }
  res.status(201).json({ message: 'Verification code sent' });
}));

router.post('/auth/verify-otp', authLimiter, asyncRoute(async (req, res) => {
  const email = requestString(req.body.email, 'Email').toLowerCase();
  const code = requestString(req.body.code, 'Code', 6);
  if (!/^\d{6}$/.test(code)) throw new HttpError(400, 'Invalid verification code');
  await inTransaction(async client => {
    const result = await client.query<{ id: string; code_hash: string }>(
      `SELECT id, code_hash FROM otp_challenges WHERE email = $1 AND consumed_at IS NULL AND expires_at > now()
       ORDER BY created_at DESC LIMIT 1 FOR UPDATE`,
      [email]
    );
    if (result.rowCount !== 1 || !(await argon2.verify(result.rows[0].code_hash, code))) {
      throw new HttpError(400, 'Invalid or expired verification code');
    }
    await client.query('UPDATE otp_challenges SET consumed_at = now() WHERE id = $1', [result.rows[0].id]);
    await client.query('UPDATE users SET email_verified_at = now() WHERE email = $1', [email]);
  });
  res.json({ message: 'Email verified' });
}));

async function issueSession(userId: string, deviceName: string) {
  const refreshToken = randomBytes(48).toString('base64url');
  const refreshTokenId = await inTransaction(async client => {
    const result = await client.query<{ id: string }>(
      `INSERT INTO refresh_tokens(user_id, token_hash, expires_at)
       VALUES ($1, $2, now() + interval '30 days') RETURNING id`,
      [userId, hash(refreshToken)]
    );
    await client.query('INSERT INTO sessions(user_id, refresh_token_id, device_name) VALUES ($1, $2, $3)', [
      userId, result.rows[0].id, deviceName.slice(0, 100)
    ]);
    return result.rows[0].id;
  });
  const accessToken = jwt.sign({ type: 'access' }, config.JWT_SECRET, { subject: userId, expiresIn: '15m' });
  return { accessToken, refreshToken, refreshTokenId };
}

router.post('/auth/login', authLimiter, asyncRoute(async (req, res) => {
  const email = requestString(req.body.email, 'Email').toLowerCase();
  const password = requestString(req.body.password, 'Password');
  const user = await pool.query<{ id: string; password_hash: string; email_verified_at: Date | null }>(
    'SELECT id, password_hash, email_verified_at FROM users WHERE email = $1 AND deleted_at IS NULL',
    [email]
  );
  if (user.rowCount !== 1 || !(await argon2.verify(user.rows[0].password_hash, password))) {
    throw new HttpError(401, 'Invalid email or password');
  }
  if (!user.rows[0].email_verified_at) throw new HttpError(403, 'Email verification required');
  const session = await issueSession(user.rows[0].id, String(req.header('user-agent') ?? 'Unknown device'));
  res.json({ accessToken: session.accessToken, refreshToken: session.refreshToken });
}));

router.post('/auth/refresh', authLimiter, asyncRoute(async (req, res) => {
  const token = requestString(req.body.refreshToken, 'Refresh token');
  const result = await pool.query<{ user_id: string; id: string }>(
    `UPDATE refresh_tokens SET revoked_at = now()
     WHERE token_hash = $1 AND revoked_at IS NULL AND expires_at > now()
     RETURNING user_id, id`,
    [hash(token)]
  );
  if (result.rowCount !== 1) throw new HttpError(401, 'Invalid or expired refresh token');
  await pool.query('UPDATE sessions SET last_seen_at = now() WHERE refresh_token_id = $1', [result.rows[0].id]);
  const session = await issueSession(result.rows[0].user_id, String(req.header('user-agent') ?? 'Unknown device'));
  res.json({ accessToken: session.accessToken, refreshToken: session.refreshToken });
}));

router.post('/auth/logout', authenticate, asyncRoute(async (req, res) => {
  const token = requestString(req.body.refreshToken, 'Refresh token');
  await pool.query('UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1 AND token_hash = $2', [
    req.userId, hash(token)
  ]);
  res.status(204).end();
}));

router.get('/wallet', authenticate, asyncRoute(async (req, res) => {
  const result = await pool.query(
    `SELECT w.balance::text AS balance_kobo, v.account_number, v.bank_name, v.expires_at
     FROM wallets w LEFT JOIN virtual_accounts v ON v.user_id = w.user_id WHERE w.user_id = $1`,
    [req.userId]
  );
  if (result.rowCount !== 1) throw new HttpError(404, 'Wallet not found');
  res.json(result.rows[0]);
}));

router.post('/wallet/virtual-account', authenticate, asyncRoute(async (req, res) => {
  const existing = await pool.query(
    'SELECT account_number, bank_name, expires_at FROM virtual_accounts WHERE user_id = $1',
    [req.userId]
  );
  if (existing.rowCount) {
    res.json(existing.rows[0]);
    return;
  }
  const bvn = requestString(req.body.bvn, 'BVN', 11);
  if (!/^\d{11}$/.test(bvn)) throw new HttpError(400, 'BVN must contain 11 digits');
  const account = await inTransaction(async client => {
    await client.query('SELECT id FROM users WHERE id = $1 FOR UPDATE', [req.userId]);
    const created = await client.query(
      'SELECT account_number, bank_name, expires_at FROM virtual_accounts WHERE user_id = $1',
      [req.userId]
    );
    if (created.rowCount) return created.rows[0];
    const user = await client.query<{ email: string; full_name: string; phone: string }>(
      'SELECT email, full_name, phone FROM users WHERE id = $1',
      [req.userId]
    );
    const names = user.rows[0].full_name.split(/\s+/);
    const providerReference = newReference('wallet');
    const response = await flwRequest<{
      status: string;
      data: { account_number: string; bank_name: string; expiry_date?: string; flw_ref?: string };
    }>('/virtual-account-numbers', {
      method: 'POST',
      body: {
        email: user.rows[0].email,
        tx_ref: providerReference,
        phonenumber: user.rows[0].phone,
        is_permanent: true,
        firstname: names[0],
        lastname: names.slice(1).join(' ') || names[0],
        narration: 'Wallet funding',
        bvn
      }
    });
    if (response.status !== 'success' || !response.data.account_number || !response.data.bank_name) {
      throw new Error('Flutterwave did not return virtual account details');
    }
    let expiresAt: Date | null = null;
    if (response.data.expiry_date && response.data.expiry_date.toUpperCase() !== 'N/A') {
      expiresAt = new Date(response.data.expiry_date);
      if (Number.isNaN(expiresAt.getTime())) throw new Error('Flutterwave returned an invalid expiry date');
    }
    const stored = await client.query(
      `INSERT INTO virtual_accounts(user_id, account_number, bank_name, provider_reference, expires_at)
       VALUES ($1, $2, $3, $4, $5) RETURNING account_number, bank_name, expires_at`,
      [req.userId, response.data.account_number, response.data.bank_name, providerReference, expiresAt]
    );
    return stored.rows[0];
  });
  res.status(201).json(account);
}));

router.post('/wallet/fund-card', authenticate, asyncRoute(async (req, res) => {
  const amount = parseKobo(req.body.amount);
  const txRef = newReference('fund');
  const customer = await pool.query<{ email: string; full_name: string }>(
    'SELECT email, full_name FROM users WHERE id = $1',
    [req.userId]
  );
  await inTransaction(async client => {
    const wallet = await client.query<{ balance: string }>('SELECT balance FROM wallets WHERE user_id = $1 FOR UPDATE', [req.userId]);
    const balance = BigInt(wallet.rows[0].balance);
    await client.query(
      `INSERT INTO wallet_funding_intents(user_id, amount, reference, status)
       VALUES ($1, $2, $3, 'pending')`,
      [req.userId, amount.toString(), txRef]
    );
  });
  const checkout = await flwRequest<{ status: string; data: { link: string } }>('/payments', {
    method: 'POST',
    body: {
      tx_ref: txRef,
      amount: koboToNairaDecimal(amount),
      currency: 'NGN',
      redirect_url: `${config.APP_BASE_URL}/payments/return`,
      customer: { email: customer.rows[0].email, name: customer.rows[0].full_name }
    }
  });
  res.status(201).json({ checkoutUrl: checkout.data.link, reference: txRef });
}));

router.get('/bills/categories', authenticate, asyncRoute(async (_req, res) => {
  res.json(await flwRequest('/bill-categories'));
}));

router.get('/bills/billers', authenticate, asyncRoute(async (req, res) => {
  const category = requestString(req.query.category, 'Category');
  if (!['AIRTIME', 'MOBILEDATA', 'UTILITYBILLS', 'CABLEBILLS'].includes(category)) {
    throw new HttpError(400, 'Unsupported bill category');
  }
  res.json(await flwRequest(`/billers?country=NG&category=${encodeURIComponent(category)}`));
}));

router.get('/bills/items', authenticate, asyncRoute(async (req, res) => {
  const biller = requestString(req.query.biller, 'Biller');
  res.json(await flwRequest(`/billers/${encodeURIComponent(biller)}/items`));
}));

router.get('/data/plans', authenticate, asyncRoute(async (req, res) => {
  const network = requestString(req.query.network, 'Network');
  const billers = await flwRequest<{
    data: Array<{ name?: string; short_name?: string; biller_code: string }>;
  }>('/billers?country=NG&category=MOBILEDATA');
  const biller = billers.data.find(item =>
    (item.name ?? '').toLowerCase() === network.toLowerCase() ||
    (item.short_name ?? '').toLowerCase() === network.toLowerCase() ||
    item.biller_code.toLowerCase() === network.toLowerCase()
  );
  if (!biller) throw new HttpError(404, 'Network not found');
  res.json(await flwRequest(`/billers/${encodeURIComponent(biller.biller_code)}/items`));
}));

router.post('/bills/validate', authenticate, asyncRoute(async (req, res) => {
  const itemCode = requestString(req.body.itemCode, 'Item code');
  const customerId = requestString(req.body.customerId, 'Customer');
  res.json(await flwRequest(`/bill-items/${encodeURIComponent(itemCode)}/validate`, {
    method: 'POST', body: { customer: customerId }
  }));
}));

async function startPurchase(req: Request, res: Response, expectedCategory?: string) {
  const userId = req.userId!;
  const idempotencyKey = req.header('idempotency-key');
  if (!idempotencyKey || !/^[a-zA-Z0-9_-]{8,100}$/.test(idempotencyKey)) {
    throw new HttpError(400, 'A valid Idempotency-Key header is required');
  }
  const category = requestString(req.body.category, 'Category').toLowerCase();
  if (expectedCategory && category !== expectedCategory) throw new HttpError(400, 'Invalid purchase category');
  if (!['airtime', 'data', 'electricity', 'cable'].includes(category)) throw new HttpError(400, 'Invalid purchase category');
  const pin = requestString(req.body.pin, 'PIN', 8);
  const user = await pool.query<{ pin_hash: string | null }>('SELECT pin_hash FROM users WHERE id = $1', [userId]);
  if (!user.rows[0].pin_hash || !(await argon2.verify(user.rows[0].pin_hash, pin))) {
    throw new HttpError(401, 'Invalid transaction PIN');
  }
  const amount = parseKobo(req.body.amount);
  const billerCode = requestString(req.body.billerCode, 'Biller code');
  const itemCode = requestString(req.body.itemCode, 'Item code');
  const recipient = requestString(req.body.recipient, 'Recipient');
  const transactionReference = `${userId}:${idempotencyKey}`;
  const providerReference = newReference('bill');
  const existing = await pool.query<{ reference: string; status: string }>(
    `SELECT t.reference, p.status FROM transactions t JOIN purchases p ON p.transaction_id = t.id
     WHERE t.user_id = $1 AND t.reference = $2`,
    [userId, transactionReference]
  );
  if (existing.rowCount) {
    res.status(202).json(existing.rows[0]);
    return;
  }
  let debit: { id: string; before: bigint; after: bigint };
  try {
    debit = await inTransaction(async client => {
      const floatState = await client.query<{ available_balance_kobo: string; last_actual_at: Date }>(
        'SELECT available_balance_kobo::text, last_actual_at FROM provider_float_state WHERE id = 1 FOR UPDATE'
      );
      if (floatState.rowCount !== 1 ||
          Date.now() - floatState.rows[0].last_actual_at.getTime() > 15 * 60_000 ||
          BigInt(floatState.rows[0].available_balance_kobo) < config.PROVIDER_FLOAT_MIN_KOBO + amount) {
        throw new HttpError(503, 'Bill payments are temporarily unavailable');
      }
      const row = await postLedgerEntry(client, {
        userId, type: 'purchase', amount, reference: transactionReference, status: 'success',
        description: `${category} purchase`, debit: true
      });
      const purchase = await client.query<{ id: string }>(
        `INSERT INTO purchases(user_id, transaction_id, category, biller_code, item_code, recipient, amount, provider_reference, status)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'pending') RETURNING id`,
        [userId, row.id, category, billerCode, itemCode, recipient, amount.toString(), providerReference]
      );
      await client.query(
        "INSERT INTO provider_float_reservations(purchase_id, amount, status) VALUES ($1, $2, 'reserved')",
        [purchase.rows[0].id, amount.toString()]
      );
      await client.query(
        'UPDATE provider_float_state SET available_balance_kobo = available_balance_kobo - $1, updated_at = now() WHERE id = 1',
        [amount.toString()]
      );
      return row;
    });
  } catch (error) {
    const duplicate = await pool.query<{ reference: string; status: string }>(
      `SELECT t.reference, p.status FROM purchases p JOIN transactions t ON t.id = p.transaction_id
       WHERE t.user_id = $1 AND t.reference = $2`,
      [userId, transactionReference]
    );
    if (duplicate.rowCount) {
      res.status(202).json(duplicate.rows[0]);
      return;
    }
    throw error;
  }
  try {
    const response = await flwRequest<{
      status: string;
      data?: { reference?: string; tx_ref?: string; code?: string };
    }>(`/billers/${encodeURIComponent(billerCode)}/items/${encodeURIComponent(itemCode)}/payment`, {
      method: 'POST',
      body: {
        country: 'NG',
        customer_id: recipient,
        amount: koboToNairaDecimal(amount),
        reference: providerReference
      }
    });
    if (response.data?.reference || response.data?.tx_ref) {
      await pool.query(
        'UPDATE purchases SET provider_reference = $2, provider_response = $3 WHERE transaction_id = $1',
        [debit.id, response.data.tx_ref ?? providerReference, response]
      );
    }
  } catch (error) {
    console.error('Bill request outcome is uncertain; reconciliation will query provider status');
    // A network failure is ambiguous: the provider may already have accepted the request.
  }
  res.status(202).json({ reference: transactionReference, status: 'pending' });
}

router.post('/purchase/airtime', authenticate, purchaseLimiter, asyncRoute(async (req, res) => startPurchase(req, res, 'airtime')));
router.post('/purchase/data', authenticate, purchaseLimiter, asyncRoute(async (req, res) => startPurchase(req, res, 'data')));
router.post('/bills/pay', authenticate, purchaseLimiter, asyncRoute(async (req, res) => startPurchase(req, res)));

router.get('/transactions', authenticate, asyncRoute(async (req, res) => {
  const limit = Math.max(1, Math.min(Number(req.query.limit) || 30, 100));
  const rows = await pool.query(
    `SELECT t.reference, t.type, t.amount::text AS amount_kobo,
            COALESCE(p.status, 'success') AS status, t.description, t.created_at
     FROM transactions t LEFT JOIN purchases p ON p.transaction_id = t.id
     WHERE t.user_id = $1
     UNION ALL
     SELECT f.reference, 'funding' AS type, f.amount::text AS amount_kobo, f.status,
            'Card wallet funding' AS description, f.created_at
     FROM wallet_funding_intents f WHERE f.user_id = $1
     ORDER BY created_at DESC LIMIT $2`,
    [req.userId, limit]
  );
  res.json(rows.rows);
}));

router.get('/transactions/:reference', authenticate, asyncRoute(async (req, res) => {
  const result = await pool.query(
    `SELECT t.reference, t.type, t.amount::text AS amount_kobo, t.balance_before::text,
            t.balance_after::text, COALESCE(p.status, 'success') AS status, t.description, t.created_at
     FROM transactions t LEFT JOIN purchases p ON p.transaction_id = t.id
     WHERE t.user_id = $1 AND t.reference = $2
     UNION ALL
     SELECT f.reference, 'funding' AS type, f.amount::text AS amount_kobo, NULL AS balance_before,
            NULL AS balance_after, f.status, 'Card wallet funding' AS description, f.created_at
     FROM wallet_funding_intents f WHERE f.user_id = $1 AND f.reference = $2`,
    [req.userId, req.params.reference]
  );
  if (!result.rowCount) throw new HttpError(404, 'Transaction not found');
  res.json(result.rows[0]);
}));

router.post('/me/pin', authenticate, asyncRoute(async (req, res) => {
  const pin = requestString(req.body.pin, 'PIN', 8);
  if (!/^\d{4,6}$/.test(pin)) throw new HttpError(400, 'PIN must contain 4 to 6 digits');
  await pool.query('UPDATE users SET pin_hash = $2, updated_at = now() WHERE id = $1', [req.userId, await argon2.hash(pin)]);
  res.status(204).end();
}));

router.get('/me', authenticate, asyncRoute(async (req, res) => {
  const result = await pool.query(
    'SELECT id, email, phone, full_name, created_at FROM users WHERE id = $1 AND deleted_at IS NULL',
    [req.userId]
  );
  if (!result.rowCount) throw new HttpError(404, 'User not found');
  res.json(result.rows[0]);
}));

router.patch('/me', authenticate, asyncRoute(async (req, res) => {
  const fullName = requestString(req.body.fullName, 'Full name');
  const phone = req.body.phone == null ? null : requestString(req.body.phone, 'Phone', 20);
  if (phone && !/^\+?[0-9]{7,15}$/.test(phone)) throw new HttpError(400, 'Invalid phone number');
  const result = await pool.query(
    'UPDATE users SET full_name = $2, phone = $3, updated_at = now() WHERE id = $1 AND deleted_at IS NULL RETURNING id, email, phone, full_name',
    [req.userId, fullName, phone]
  );
  if (!result.rowCount) throw new HttpError(404, 'User not found');
  res.json(result.rows[0]);
}));

router.post('/me/password', authenticate, asyncRoute(async (req, res) => {
  const currentPassword = requestString(req.body.currentPassword, 'Current password');
  const newPassword = requestString(req.body.newPassword, 'New password');
  if (newPassword.length < 10) throw new HttpError(400, 'Password must be at least 10 characters');
  const result = await pool.query<{ password_hash: string }>('SELECT password_hash FROM users WHERE id = $1', [req.userId]);
  if (!(await argon2.verify(result.rows[0].password_hash, currentPassword))) {
    throw new HttpError(401, 'Current password is incorrect');
  }
  await pool.query('UPDATE users SET password_hash = $2, updated_at = now() WHERE id = $1', [
    req.userId, await argon2.hash(newPassword)
  ]);
  await pool.query('UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1', [req.userId]);
  res.status(204).end();
}));

router.get('/me/sessions', authenticate, asyncRoute(async (req, res) => {
  const result = await pool.query(
    `SELECT s.id, s.device_name, s.created_at, s.last_seen_at
     FROM sessions s JOIN refresh_tokens r ON r.id = s.refresh_token_id
     WHERE s.user_id = $1 AND r.revoked_at IS NULL AND r.expires_at > now()
     ORDER BY s.last_seen_at DESC`,
    [req.userId]
  );
  res.json(result.rows);
}));

router.delete('/me/sessions/:id', authenticate, asyncRoute(async (req, res) => {
  const result = await pool.query(
    `UPDATE refresh_tokens SET revoked_at = now()
     WHERE id = (SELECT refresh_token_id FROM sessions WHERE id = $1 AND user_id = $2)`,
    [req.params.id, req.userId]
  );
  if (!result.rowCount) throw new HttpError(404, 'Session not found');
  res.status(204).end();
}));

router.get('/me/notification-settings', authenticate, asyncRoute(async (req, res) => {
  const result = await pool.query(
    'SELECT push_enabled, email_enabled, transaction_alerts FROM notification_settings WHERE user_id = $1',
    [req.userId]
  );
  if (!result.rowCount) throw new HttpError(404, 'Notification settings not found');
  res.json(result.rows[0]);
}));

router.put('/me/notification-settings', authenticate, asyncRoute(async (req, res) => {
  const fields = ['pushEnabled', 'emailEnabled', 'transactionAlerts'] as const;
  for (const field of fields) {
    if (typeof req.body[field] !== 'boolean') throw new HttpError(400, `${field} must be a boolean`);
  }
  const result = await pool.query(
    `UPDATE notification_settings SET push_enabled = $2, email_enabled = $3, transaction_alerts = $4, updated_at = now()
     WHERE user_id = $1 RETURNING push_enabled, email_enabled, transaction_alerts`,
    [req.userId, req.body.pushEnabled, req.body.emailEnabled, req.body.transactionAlerts]
  );
  res.json(result.rows[0]);
}));

router.put('/me/push-token', authenticate, asyncRoute(async (req, res) => {
  const token = requestString(req.body.token, 'Push token', 4096);
  const platform = requestString(req.body.platform, 'Platform');
  if (platform !== 'android' && platform !== 'ios') throw new HttpError(400, 'Unsupported platform');
  await pool.query(
    `INSERT INTO push_tokens(user_id, token, platform) VALUES ($1, $2, $3)
     ON CONFLICT (token) DO UPDATE SET user_id = EXCLUDED.user_id, platform = EXCLUDED.platform, updated_at = now()`,
    [req.userId, token, platform]
  );
  res.status(204).end();
}));

router.delete('/me/push-token', authenticate, asyncRoute(async (req, res) => {
  const token = requestString(req.body.token, 'Push token', 4096);
  await pool.query('DELETE FROM push_tokens WHERE user_id = $1 AND token = $2', [req.userId, token]);
  res.status(204).end();
}));

router.get('/beneficiaries', authenticate, asyncRoute(async (req, res) => {
  const result = await pool.query(
    'SELECT id, name, category, recipient, biller_code, item_code, created_at FROM beneficiaries WHERE user_id = $1 ORDER BY created_at DESC',
    [req.userId]
  );
  res.json(result.rows);
}));

router.post('/beneficiaries', authenticate, asyncRoute(async (req, res) => {
  const name = requestString(req.body.name, 'Name');
  const category = requestString(req.body.category, 'Category');
  const recipient = requestString(req.body.recipient, 'Recipient');
  const billerCode = typeof req.body.billerCode === 'string' ? req.body.billerCode : null;
  const itemCode = typeof req.body.itemCode === 'string' ? req.body.itemCode : null;
  const result = await pool.query(
    `INSERT INTO beneficiaries(user_id, name, category, recipient, biller_code, item_code)
     VALUES ($1, $2, $3, $4, $5, $6) RETURNING id, name, category, recipient, biller_code, item_code`,
    [req.userId, name, category, recipient, billerCode, itemCode]
  );
  res.status(201).json(result.rows[0]);
}));

router.delete('/beneficiaries/:id', authenticate, asyncRoute(async (req, res) => {
  const result = await pool.query('DELETE FROM beneficiaries WHERE id = $1 AND user_id = $2', [
    req.params.id, req.userId
  ]);
  if (!result.rowCount) throw new HttpError(404, 'Beneficiary not found');
  res.status(204).end();
}));

router.delete('/me', authenticate, asyncRoute(async (req, res) => {
  const result = await pool.query(
    `SELECT w.balance,
       EXISTS(SELECT 1 FROM purchases p WHERE p.user_id = w.user_id AND p.status = 'pending')
       OR EXISTS(SELECT 1 FROM wallet_funding_intents f WHERE f.user_id = w.user_id AND f.status = 'pending') AS has_pending
     FROM wallets w WHERE w.user_id = $1 FOR UPDATE`,
    [req.userId]
  );
  if (!result.rowCount) throw new HttpError(404, 'Wallet not found');
  if (BigInt(result.rows[0].balance) > 0n || result.rows[0].has_pending) {
    throw new HttpError(409, 'Account cannot be deleted while funds or pending transactions remain');
  }
  await pool.query('UPDATE users SET deleted_at = now(), updated_at = now() WHERE id = $1', [req.userId]);
  await pool.query('UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1', [req.userId]);
  res.status(204).end();
}));

router.post('/webhooks/flutterwave', asyncRoute(async (req, res) => {
  const given = req.header('verif-hash') ?? '';
  const expected = config.FLW_WEBHOOK_SECRET;
  const givenBuffer = Buffer.from(given);
  const expectedBuffer = Buffer.from(expected);
  if (givenBuffer.length !== expectedBuffer.length || !timingSafeEqual(givenBuffer, expectedBuffer)) {
    throw new HttpError(401, 'Invalid webhook signature');
  }
  const payload = req.body as {
    event?: string;
    data?: { id?: number | string; tx_ref?: string; reference?: string; amount?: string | number; currency?: string; status?: string };
  };
  const transactionId = payload.data?.id;
  const txRef = payload.data?.tx_ref;
  if (!transactionId || !txRef) throw new HttpError(400, 'Invalid webhook payload');
  const event = await pool.query<{ id: string; processed_at: Date | null }>(
    `INSERT INTO webhook_events(provider_event_id, event_type, payload)
     VALUES ($1, $2, $3) ON CONFLICT (provider_event_id) DO NOTHING RETURNING id`,
    [String(transactionId), payload.event ?? 'unknown', JSON.stringify(payload)]
  );
  let eventId: string;
  if (!event.rowCount) {
    const existingEvent = await pool.query<{ id: string; processed_at: Date | null }>(
      'SELECT id, processed_at FROM webhook_events WHERE provider_event_id = $1',
      [String(transactionId)]
    );
    if (existingEvent.rows[0].processed_at) {
      res.status(200).json({ received: true });
      return;
    }
    eventId = existingEvent.rows[0].id;
  } else {
    eventId = event.rows[0].id;
  }
  if (payload.event === 'charge.completed') {
    const verified = await flwRequest<{
      status: string;
      data: { id: number; tx_ref: string; status: string; amount: string | number; currency: string; flw_ref?: string };
    }>(`/transactions/${encodeURIComponent(String(transactionId))}/verify`);
    const tx = verified.data;
    if (verified.status !== 'success' || tx.tx_ref !== txRef ||
        tx.currency !== 'NGN' || parseKobo(tx.amount) !== parseKobo(payload.data?.amount ?? 0)) {
      await pool.query('UPDATE webhook_events SET processed_at = now(), processing_error = $2 WHERE id = $1', [
          eventId, 'Flutterwave verification did not match webhook'
      ]);
      res.status(200).json({ received: true });
      return;
    }
    await inTransaction(async client => {
      const matched = await client.query<{ reference: string; amount: string }>(
          'SELECT reference, amount::text FROM wallet_funding_intents WHERE reference = $1 AND status = $2 FOR UPDATE',
          [txRef, 'pending']
      );
      if (matched.rowCount === 1 && BigInt(matched.rows[0].amount) === parseKobo(tx.amount)) {
        if (tx.status === 'successful') {
          await setTransactionStatus(client, txRef, 'success', String(tx.id), tx.flw_ref);
        } else if (tx.status === 'failed') {
          await setTransactionStatus(client, txRef, 'failed', String(tx.id), tx.flw_ref);
        }
      } else if (matched.rowCount === 0 && tx.status === 'successful') {
          const virtualAccount = await client.query<{ user_id: string }>(
            'SELECT user_id FROM virtual_accounts WHERE provider_reference = $1 FOR UPDATE',
            [txRef]
          );
          if (virtualAccount.rowCount === 1) {
            await postLedgerEntry(client, {
              userId: virtualAccount.rows[0].user_id,
              type: 'funding',
              amount: parseKobo(tx.amount),
              reference: `virtual:${tx.id}`,
              status: 'success',
              description: 'Virtual account wallet funding',
              providerTransactionId: String(tx.id),
              providerReference: tx.flw_ref
            });
          }
      }
      await client.query('UPDATE webhook_events SET processed_at = now() WHERE id = $1', [eventId]);
    });
  } else {
    await pool.query('UPDATE webhook_events SET processed_at = now() WHERE id = $1', [eventId]);
  }
  res.status(200).json({ received: true });
}));

router.get('/admin/transactions', asyncRoute(async (req, res) => {
  const key = config.ADMIN_API_KEY;
  if (!key || req.header('x-admin-key') !== key) throw new HttpError(401, 'Admin authentication required');
  const status = req.query.status;
  if (status !== 'failed' && status !== 'pending') throw new HttpError(400, 'Status must be failed or pending');
  const result = await pool.query(
    `SELECT t.reference, t.user_id, t.type, t.amount::text AS amount_kobo, p.status, t.created_at
     FROM purchases p JOIN transactions t ON t.id = p.transaction_id WHERE p.status = $1
     UNION ALL
     SELECT reference, user_id, 'funding' AS type, amount::text AS amount_kobo, status, created_at
     FROM wallet_funding_intents WHERE status = $1 ORDER BY created_at DESC LIMIT 100`,
    [status]
  );
  res.json(result.rows);
}));

router.get('/admin/provider-balance', asyncRoute(async (req, res) => {
  const key = config.ADMIN_API_KEY;
  if (!key || req.header('x-admin-key') !== key) throw new HttpError(401, 'Admin authentication required');
  const result = await pool.query(
    `SELECT s.currency, s.balance_kobo::text AS actual_balance_kobo, s.source, s.recorded_at,
            f.available_balance_kobo::text, f.last_actual_at
     FROM provider_balance_snapshots s CROSS JOIN provider_float_state f
     WHERE f.id = 1 ORDER BY s.recorded_at DESC LIMIT 1`
  );
  if (!result.rowCount) throw new HttpError(503, 'Provider balance has not been recorded');
  const belowThreshold = BigInt(result.rows[0].available_balance_kobo) < config.PROVIDER_FLOAT_MIN_KOBO;
  res.json({ ...result.rows[0], belowThreshold });
}));

router.post('/admin/provider-balance', asyncRoute(async (req, res) => {
  const key = config.ADMIN_API_KEY;
  if (!key || req.header('x-admin-key') !== key) throw new HttpError(401, 'Admin authentication required');
  const raw = req.body.balanceKobo;
  if (typeof raw !== 'string' || !/^(0|[1-9]\d*)$/.test(raw)) {
    throw new HttpError(400, 'balanceKobo must be an integer string');
  }
  const source = requestString(req.body.source, 'Source', 80);
  const balance = BigInt(raw);
  const result = await inTransaction(async client => {
    await client.query('SELECT id FROM provider_float_state WHERE id = 1 FOR UPDATE');
    const pending = await client.query<{ amount: string }>(
      `SELECT COALESCE(sum(p.amount), 0)::text AS amount
       FROM purchases p WHERE p.status = 'pending'`
    );
    const reserved = BigInt(pending.rows[0].amount);
    const available = balance > reserved ? balance - reserved : 0n;
    const snapshot = await client.query(
      `INSERT INTO provider_balance_snapshots(currency, balance_kobo, source)
       VALUES ('NGN', $1, $2) RETURNING balance_kobo::text, recorded_at`,
      [raw, source]
    );
    await client.query(
      `INSERT INTO provider_float_state(id, available_balance_kobo, actual_balance_kobo, last_actual_at)
       VALUES (1, $1, $2, now())
       ON CONFLICT (id) DO UPDATE SET available_balance_kobo = EXCLUDED.available_balance_kobo,
         actual_balance_kobo = EXCLUDED.actual_balance_kobo, last_actual_at = EXCLUDED.last_actual_at, updated_at = now()`,
      [available.toString(), raw]
    );
    return { ...snapshot.rows[0], available_balance_kobo: available.toString() };
  });
  const availableBalance = BigInt(result.available_balance_kobo);
  if (availableBalance < config.PROVIDER_FLOAT_MIN_KOBO) console.warn('Provider float is below the configured threshold');
  res.status(201).json({
    ...result,
    belowThreshold: availableBalance < config.PROVIDER_FLOAT_MIN_KOBO
  });
}));

export { router as apiRouter };
