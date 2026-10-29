# NaijaPay

Flutter mobile app and TypeScript/Express API for NGN wallet funding and Nigerian bill payments.

## Repository layout

```text
backend/
  migrations/       PostgreSQL schema
  src/              Express API, wallet ledger, Flutterwave integration, reconciliation
mobile/
  lib/core/         Dio API client and secure token storage
  lib/screens/      Authentication, wallet, bills, history, and settings
```

## Backend

1. Copy `.env.example` to `backend/.env` and configure server-only secrets.
2. Set `DATABASE_URL` to the Neon pooled URL and `DIRECT_URL` to the direct migration URL.
3. From `backend/`, run `npm install`, `npm run migrate`, and `npm run dev`.
4. Configure Flutterwave's webhook URL as `https://<api-host>/webhooks/flutterwave` and set the same random webhook secret in `FLW_WEBHOOK_SECRET`.
5. Configure SMTP. Registration OTPs are stored as hashes and are never returned by the API.

Run `npm run build` to type-check and build the API.

### Financial controls

- Amounts are `BIGINT` kobo in PostgreSQL and converted to decimal NGN strings only at the Flutterwave API boundary.
- Wallet debits take a `SELECT ... FOR UPDATE` lock and are protected by `CHECK (balance >= 0)`.
- `transactions` is append-only; purchase state is tracked separately. Failed bills get a compensating refund ledger entry.
- Purchase requests require a client `Idempotency-Key`, transaction PIN, and a recent provider-float snapshot above the configured reserve.
- Funding webhook messages are checked with Flutterwave's `verif-hash` header and then verified by transaction ID before wallet credit.
- Unknown bill outcomes remain pending. A worker polls Flutterwave's bill-status endpoint and refunds only confirmed failures.

The current Flutterwave documentation does not describe a provider balance API in the bill-payment integration guide. Until an account-specific supported balance endpoint is enabled, an operator must submit an authoritative provider balance in kobo using `POST /admin/provider-balance` with `x-admin-key`. The service records timestamped snapshots, alerts in logs below the configured threshold, and blocks purchases when the latest snapshot is older than 15 minutes or insufficient. Do not treat estimated balances as authoritative.

Permanent NGN virtual accounts require a BVN or NIN per Flutterwave's current docs. The mobile flow requests BVN for provisioning and sends it only to the backend for the Flutterwave request; it is not stored in the app database.

## Mobile

From `mobile/`, run `flutter pub get`, then launch the Windows desktop app:

```powershell
flutter run -d windows --dart-define=API_BASE_URL=http://localhost:3000
```

If Windows is missing from `flutter devices`, run `flutter config --enable-windows-desktop` and regenerate the target from `mobile/` with `flutter create --platforms=windows .`. Windows desktop development requires Visual Studio with the **Desktop development with C++** workload, including the MSVC toolchain and a Windows SDK.

For Android emulator development, use `--dart-define=API_BASE_URL=http://10.0.2.2:3000`. Configure Firebase platform files/options and run with `--dart-define=FIREBASE_ENABLED=true` to register FCM tokens. Flutterwave keys are not part of the mobile app. Account, OTP, PIN, and balance screens enable Android `FLAG_SECURE`. Windows/Linux/web and iOS cannot block screenshots through a supported app API; the app reports this limitation on protected screens. Biometric unlock is a local app-unlock option; transaction execution still requires the server-verified PIN.

## Current Flutterwave API references

Integration uses the Flutterwave v3 REST API. Documentation pages were checked on 26 October 2026:

- [Authentication](https://developer.flutterwave.com/docs/authentication.md) — server-side secret key sent as `Authorization: Bearer <secret>`.
- [Webhooks](https://developer.flutterwave.com/docs/webhooks.md) — secret hash arrives in `verif-hash`; transaction verification is still required.
- [Transaction verification](https://developer.flutterwave.com/docs/transaction-verification.md) — `GET /v3/transactions/{id}/verify`.
- [NGN virtual accounts](https://developer.flutterwave.com/docs/ngn-virtual-accounts.md) — static accounts, identity requirements, and transfer webhook fields.
- [Bill payments](https://developer.flutterwave.com/docs/bill-payment.md) — bill catalog, validation, payment, and status flow.
- [Create bill payment](https://developer.flutterwave.com/reference/create-a-bill-payment.md) — `POST /v3/billers/{biller_code}/items/{item_code}/payment`.
- [Bill status](https://developer.flutterwave.com/reference/get-status-of-a-bill-payment.md) — `GET /v3/bills/{reference}?verbose=1`.
