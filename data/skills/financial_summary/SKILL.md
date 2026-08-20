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

## Where the amount comes from

The listing snippet usually already contains the total — receipts lead with it.
Read it from there. Only when the snippet genuinely cuts the number off should
you open the message, and then **collect every such id and make ONE batched read
call**, not one per receipt (see "Reading efficiently" in
[email_triage](../email_triage/SKILL.md)).

A Paper Trail box of forty receipts is not forty reads. It is one listing, then
at most one batched read for the handful whose totals the snippet truncated.

## Never add up money yourself — and keep currencies apart

When you roll payments up into totals, **call the `SumPayments` tool** with every
payment that belongs in the briefing, in one call, and copy its answer through. Do
not add the numbers yourself and do not re-derive the totals afterwards.

It returns `by_currency`, where **each currency is a self-contained block carrying
its own `charges` list AND its own totals** computed from exactly that list. Write
both from the same block. This is not a style preference: when the totals and the
list were produced separately they drifted — a real run reported USD
`charged: 289.00` against its own list summing to `269.00`, and MXN
`refund: 7,979.84` against a list summing to `7,899.98` with a count of 5 for four
entries.

**Never merge currencies.** Not in a total, not in a chart, not in a sentence. There
is no exchange rate here and the tool will never invent one — MXN 7,899.98 and USD
1,138.00 are two facts, not one. Report them as separate blocks, biggest `out`
first.

The tool is a calculator, nothing more: it does not know what today is and will add
up whatever you give it. **Deciding which payments belong is your job** — filter to
the run window before you call it.

If it returns `needs_direction` or `ignored`, those payments were NOT counted. Fix
the `direction` or `amount` and call again, or leave them out and say so — never
fold them into a total by hand.

## When unsure

If you cannot read a definite amount, omit `payment` and let the message stand
on its `category`/`summary` alone. The money picture is built only from numbers
you actually saw. That is always the right answer — never spend an extra round
trip chasing a number, and never estimate one to avoid the omission.
