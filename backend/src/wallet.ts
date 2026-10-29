import { PoolClient } from 'pg';
import { HttpError } from './errors';

export async function postLedgerEntry(
  client: PoolClient,
  input: {
    userId: string;
    type: 'funding' | 'purchase' | 'refund' | 'adjustment';
    amount: bigint;
    reference: string;
    status: 'pending' | 'success' | 'failed';
    description: string;
    providerTransactionId?: string;
    providerReference?: string;
    debit?: boolean;
  }
) {
  if (input.status !== 'success') throw new Error('Ledger entries must be final and append-only');
  const wallet = await client.query<{ balance: string }>(
    'SELECT balance FROM wallets WHERE user_id = $1 FOR UPDATE',
    [input.userId]
  );
  if (wallet.rowCount !== 1) throw new HttpError(404, 'Wallet not found');
  const before = BigInt(wallet.rows[0].balance);
  const delta = input.debit ? -input.amount : input.amount;
  const after = before + delta;
  if (after < 0n) throw new HttpError(402, 'Insufficient wallet balance');

  const inserted = await client.query<{ id: string }>(
    `INSERT INTO transactions
      (user_id, type, amount, balance_before, balance_after, reference, status, provider_transaction_id, provider_reference, description)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
     RETURNING id`,
    [
      input.userId,
      input.type,
      input.amount.toString(),
      before.toString(),
      after.toString(),
      input.reference,
      input.status,
      input.providerTransactionId ?? null,
      input.providerReference ?? null,
      input.description
    ]
  );
  await client.query('UPDATE wallets SET balance = $2, updated_at = now() WHERE user_id = $1', [
    input.userId,
    after.toString()
  ]);
  return { id: inserted.rows[0].id, before, after };
}

export async function setTransactionStatus(
  client: PoolClient,
  reference: string,
  status: 'success' | 'failed',
  providerTransactionId?: string,
  providerReference?: string
) {
  const funding = await client.query<{ user_id: string; amount: string; status: string }>(
    'SELECT user_id, amount::text, status FROM wallet_funding_intents WHERE reference = $1 FOR UPDATE',
    [reference]
  );
  if (funding.rowCount === 1) {
    if (funding.rows[0].status !== 'pending') return false;
    if (status === 'success') {
      await postLedgerEntry(client, {
        userId: funding.rows[0].user_id,
        type: 'funding',
        amount: BigInt(funding.rows[0].amount),
        reference,
        status: 'success',
        description: 'Wallet funding',
        providerTransactionId,
        providerReference
      });
    }
    await client.query(
      'UPDATE wallet_funding_intents SET status = $2, provider_transaction_id = $3, updated_at = now() WHERE reference = $1',
      [reference, status, providerTransactionId ?? null]
    );
    return true;
  }

  const purchase = await client.query<{ id: string; status: string; amount: string; user_id: string }>(
    'SELECT id, status, amount::text, user_id FROM purchases WHERE transaction_id = (SELECT id FROM transactions WHERE reference = $1) FOR UPDATE',
    [reference]
  );
  if (purchase.rowCount !== 1 || purchase.rows[0].status !== 'pending') return false;
  if (status === 'failed') {
    await postLedgerEntry(client, {
      userId: purchase.rows[0].user_id,
      type: 'refund',
      amount: BigInt(purchase.rows[0].amount),
      reference: `refund:${reference}`,
      status: 'success',
      description: `Refund for ${reference}`
    });
  }
  const reservation = await client.query<{ amount: string }>(
    'UPDATE provider_float_reservations SET status = $2 WHERE purchase_id = $1 AND status = $3 RETURNING amount::text',
    [purchase.rows[0].id, status === 'failed' ? 'released' : 'settled', 'reserved']
  );
  if (status === 'failed' && reservation.rowCount) {
    await client.query(
      'UPDATE provider_float_state SET available_balance_kobo = available_balance_kobo + $1, updated_at = now() WHERE id = 1',
      [reservation.rows[0].amount]
    );
  }
  await client.query('UPDATE purchases SET status = $2, updated_at = now() WHERE id = $1', [
    purchase.rows[0].id, status
  ]);
  return true;
}
