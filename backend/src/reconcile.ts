import { pool, inTransaction } from './db';
import { flwRequest } from './flutterwave';
import { setTransactionStatus } from './wallet';

export async function reconcilePendingPurchases() {
  const pending = await pool.query<{
    reference: string;
    provider_reference: string;
  }>(
    `SELECT t.reference, p.provider_reference
     FROM purchases p JOIN transactions t ON t.id = p.transaction_id
     WHERE p.status = 'pending' AND p.provider_reference IS NOT NULL
     ORDER BY p.updated_at LIMIT 50`
  );
  for (const purchase of pending.rows) {
    try {
      const response = await flwRequest<{
        status: string;
        data?: { status?: string; tx_ref?: string };
      }>(`/bills/${encodeURIComponent(purchase.provider_reference)}?verbose=1`);
      const providerStatus = response.data?.status?.toLowerCase();
      if (providerStatus === 'successful' || providerStatus === 'success') {
        await inTransaction(client =>
          setTransactionStatus(client, purchase.reference, 'success')
        );
      } else if (providerStatus === 'failed' || providerStatus === 'failure') {
        await inTransaction(client =>
          setTransactionStatus(client, purchase.reference, 'failed')
        );
      }
    } catch {
      console.error('Purchase status reconciliation failed; purchase remains pending');
    }
  }
}
