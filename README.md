# Simple Transaction Ranking Backend

A small FastAPI app that serves both the backend APIs and a simple live UI from the same service.

## What It Uses

- Python + FastAPI
- Supabase Postgres through RPC functions
- Plain HTML, CSS, and JavaScript served by the backend

The Supabase publishable key is used only to call controlled SQL functions. Tables are protected with RLS and direct table access is revoked from `anon` and `authenticated`.

## Setup

1. Make sure the Supabase database schema is installed.

   This app expects these Supabase objects to already exist:

   - `user_stats` table for per-user totals
   - `transactions` table with a unique `request_id`
   - `record_transaction(...)` RPC function
   - `get_summary(...)` RPC function
   - `get_ranking(...)` RPC function

2. Create local environment variables.

   ```bash
   cp .env.example .env
   ```

   Then put your actual Supabase values in `.env`.

3. Install dependencies.

   ```bash
   python -m venv .venv
   .venv\Scripts\activate
   pip install -r requirements.txt
   ```

4. Run the app.

   ```bash
   uvicorn app.main:app --reload
   ```

5. Open the UI.

   ```text
   http://127.0.0.1:8000
   ```

## APIs

### `POST /transaction`

Creates one transaction and updates the user's summary.

Request:

```json
{
  "request_id": "req_12345678",
  "user_id": "alice_01",
  "amount": "120.00",
  "transaction_type": "purchase"
}
```

Rules:

- `request_id` is required and must be unique for a new transaction.
- `user_id` must be 3-40 characters using letters, numbers, `_`, or `-`.
- `amount` must be greater than `0`, at most `100000`, and use up to 2 decimals.
- `transaction_type` can be `purchase` or `refund`.

If the same `request_id` is sent again with the same payload, the API returns the original transaction as a duplicate and does not update totals again. If the same `request_id` is reused with different data, the API returns `409 Conflict`.

### `GET /summary/:userId`

Returns the aggregate state for one user.

Example:

```text
GET /summary/alice_01
```

Response:

```json
{
  "user_id": "alice_01",
  "total_amount": 120.0,
  "transaction_count": 1,
  "points": 120,
  "last_transaction_at": "2026-06-24T10:00:00Z"
}
```

Unknown users return a zero summary.

### `GET /ranking`

Returns ranked users.

Optional query:

```text
GET /ranking?limit=10
```

## Ranking Calculation

The ranking is intentionally based on more than one factor:

```text
score = capped points + activity bonus + recency bonus - burst penalty
```

- Purchases add points.
- Refunds remove points.
- A single transaction can add or remove at most `500` points, so one huge transaction cannot dominate the board.
- Activity bonus is `min(transaction_count, 30) * 5`.
- Recency bonus is `30` for activity in the last 7 days, `10` for activity in the last 30 days, otherwise `0`.
- Burst penalty applies when a user has more than 20 accepted transactions in the last minute.

Ties are broken by score, points, transaction count, latest activity, and finally user ID.

## Duplicate And Concurrency Handling

Duplicate prevention is handled in the database:

- `transactions.request_id` has a unique constraint.
- `record_transaction(...)` checks existing request IDs.
- Same request ID + same payload returns `duplicate: true`.
- Same request ID + different payload raises a conflict.

Consistency is also handled in the database:

- The transaction insert and summary update happen inside one Supabase Postgres function call.
- The function locks the user's `user_stats` row with `FOR UPDATE`.
- Concurrent updates for the same user are serialized.
- The idempotency key still protects duplicate submissions during races.

## Basic Abuse Prevention

- Request validation exists in both FastAPI and the SQL function.
- A user can only create 5 accepted transactions per 10 seconds.
- Ranking caps per-transaction points.
- Ranking adds a burst penalty for very high short-term activity.
- Refunds reduce totals and points.

## Assumptions And Limitations

- The submitted Supabase key is a publishable key, not a service-role key, so schema creation must be done once through the Supabase SQL editor before the app runs.
- This demo does not include authentication. In a production app, the backend should use authenticated users and a server-only Supabase service role key.
- The UI is intentionally simple and is served from the backend at `/`.
- Deploy the backend on Railway. The live frontend link is the same deployed backend URL because the backend serves the UI.

## Suggested Video Walkthrough

For the 3-5 minute video:

1. Show the UI and submit a purchase.
2. Submit the same request again and show `duplicate: true`.
3. Change the request ID and submit another transaction.
4. Show `GET /summary/:userId`.
5. Show `/ranking` and explain the score formula.
6. Explain that the SQL RPC function handles the atomic insert/update and row lock.

## Railway Deployment

The app includes `railway.json` and a `Procfile`.

On Railway:

1. Create a new project from the GitHub repository.
2. Add these environment variables in Railway:

   ```text
   SUPABASE_URL=<your Supabase project URL>
   SUPABASE_KEY=<your Supabase publishable key>
   ```

3. Deploy. Railway will run:

   ```bash
   uvicorn app.main:app --host 0.0.0.0 --port $PORT
   ```

The frontend is served at the Railway service root URL.
