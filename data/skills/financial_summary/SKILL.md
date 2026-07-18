---
name: financial_summary
description: Identify and normalize money in an inbox — receipts, invoices, charges, bills, subscriptions, refunds, and payment-due notices — into a consistent `payment` object so a spend picture (totals + chart) can be built. Never fabricate amounts.
---

# Financial Extraction

Whenever a message is about money the reader paid, was charged, owes, or was
refunded, attach a `payment` object to that item. This is what powers the money
picture on the dashboard — the totals, the subscription list, and the chart.
Accuracy beats completeness: **a wrong number is worse than a missing one.**

## The `payment` object

```json
{
  "merchant": "GitHub",
  "amount": 4.00,
  "currency": "USD",
  "direction": "charged",
  "kind": "subscription",
  "due_date": null
}
```

| Field | Meaning |
|---|---|
| `merchant` | Who was paid / who billed. The company, not the email sender bot. |
| `amount` | The number ONLY — no symbols, no thousands separators. `1234.50`, not `"$1,234.50"`. A real value you read in the message; never estimated. |
| `currency` | ISO code, upper-case: `USD`, `EUR`, `MXN`, `GBP`… Infer from the symbol (`$`→`USD` unless context says otherwise, `€`→`EUR`, `£`→`GBP`). If truly unknown, use `null`. |
| `direction` | `paid` (you completed a payment) · `charged` (a card/account was billed, incl. receipts) · `due` (a bill/invoice awaiting payment) · `refund` (money returned to you). |
| `kind` | `one_time` or `subscription` (recurring — "monthly", "annual", "your plan renews"). |
| `due_date` | ISO date when a `due` payment is owed; otherwise `null`. |

## How to read amounts

- Take the **total**, not a line item — the "Total", "Amount charged", "Amount
  due", or "Grand total". If a receipt lists subtotal + tax + total, use the total.
- Strip currency symbols and grouping: `MX$1,299.00` → `amount: 1299.00`,
  `currency: "MXN"`.
- Decimal comma locales: `1.234,56 €` → `amount: 1234.56`, `currency: "EUR"`.
- A refund is a positive `amount` with `direction: "refund"` — don't negate it.
- Free / $0 receipts: skip the `payment` object entirely.

## What counts

Attach `payment` to: purchase receipts, order confirmations with a charged
amount, invoices, bills, subscription renewal notices, payment reminders,
refund confirmations, payout notifications.

Do **not** attach it to: marketing about prices you didn't act on, "you could
save $X" promotions, price-drop alerts, or anything where no real transaction
touched the reader's money.

## Always-financial senders

**Any** message from these senders is financial — always emit it with a
`payment`, even when it's a statement, schedule, contribution, withdrawal,
return, or interest notice rather than a plain receipt. These are the reader's
lending/investment accounts and the money picture must include them:

- **Briq**
- **Yo Te Presto** (also "YoTePresto" / "yotepresto")

Extract the most relevant figure: a contribution or deposit → `paid`; a return,
payout, or interest credited → `refund`; a payment owed or upcoming → `due`; an
amount debited/charged → `charged`. Currency is usually **MXN** unless the
message says otherwise. If a message truly carries no number, still keep the item
(category `payment`) and note it in the summary — just omit `amount` so it isn't
double-counted in totals.

## De-duplicate transactions

One real transaction often generates several emails — an order confirmation, a
receipt, and a bank/card alert for the *same* charge. Treat them as ONE payment:
when merchant + amount match and the dates are within a day or two, emit a single
`payment`, not three. Prefer the message with the clearest total. This keeps the
money totals honest. (Cross-source de-duplication of the same email is handled in
synthesis; this is about collapsing multiple emails describing one charge.)

## When unsure

If you cannot read a definite amount, omit `payment` and let the message stand
on its `category`/`summary` alone. The money picture is built only from numbers
you actually saw.
