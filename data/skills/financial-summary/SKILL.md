---
name: financial-summary
description: Identify and normalize money in an inbox — receipts, invoices, charges, bills, statements, subscriptions, refunds, payouts and income — into a consistent `payment` object, and build the money picture from the record with the money_report tool. Never fabricate amounts.
---

# Financial Extraction

Whenever a message is about money the reader paid, was charged, owes, received,
or was refunded, attach a `payment` object to that item. This is what powers the money
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
  "date": "2026-07-15",
  "due_date": null
}
```

| Field | Meaning |
|---|---|
| `merchant` | Who was paid / who billed. The company, not the email sender bot. |
| `amount` | The number ONLY — no symbols, no thousands separators. `1234.50`, not `"$1,234.50"`. A real value you read in the message; never estimated. `null` only for a bill that states no figure (see below). |
| `currency` | ISO code, upper-case: `USD`, `EUR`, `MXN`, `GBP`… Infer from the symbol (`$`→`USD` unless context says otherwise, `€`→`EUR`, `£`→`GBP`). If truly unknown, use `null`. |
| `direction` | `paid` (you completed a payment) · `charged` (a card/account was billed, incl. receipts) · `due` (a bill, invoice or statement awaiting payment) · `income` (money that came IN: a client paid you, payroll, a payout, interest or returns credited) · `refund` (money you had spent, returned to you). |
| `kind` | `one_time` · `subscription` (recurring — "monthly", "annual", "your plan renews") · `bill` (a utility or service bill: electricity, phone, internet) · `statement` (a card or account statement). |
| `date` | ISO date the money moved, when the message states one; otherwise omit it and the message date is used. |
| `due_date` | ISO date when a `due` payment is owed; otherwise `null`. |

**Income is not a refund.** Payroll paying the reader, a client's transfer arriving,
a payout: `income`. A refund is only money coming BACK from something he bought.
Filing income as a refund is how a pay run was once reported as a return.

**A bill with no figure is still a bill.** When a notice says a payment is owed but
states no amount anywhere — not in the snippet and not in the body — emit `payment`
with `direction: "due"`, `amount: null`, and the `due_date` if given. It is listed
as an open bill and adds nothing to any total.

**Statements.** A card or account statement is `kind: "statement"`, `direction:
"due"`, with the amount to pay (the payment due, else the full balance) and the
`due_date`.

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
payout, or interest credited → `income`; a payment owed or upcoming → `due`; an
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
Read it from there.

**A money message whose snippet shows no amount MUST be opened.** This is the one
place a body read is required rather than optional: a bill, statement, payout or
receipt without its figure is worth almost nothing to the money picture, and most
of the reader's bills and statements were once recorded with no amount at all for
exactly this reason. Collect every such id and make ONE batched read call (see
"Reading efficiently" in [email-triage](../email-triage/SKILL.md)); money reads
have their own allowance there. If the body has no figure either, record the bill
with `amount: null`.

A Paper Trail box of forty receipts is still not forty reads. It is one listing,
then one batched read for the ones whose totals the snippet did not show.

## The money picture comes from `money_report`

When you build the digest, **call `money_report`** — do not gather payments, do not
add anything up, and do not write `finance` yourself. The tool reads every payment
on record, computes the section and hands it to `commit_digest`.

- Each currency is a self-contained block carrying its own rows AND the totals of
  exactly those rows: `income`, `refund`, `paid`, `charged`, `due`, `out`, `in`,
  `net`.
- **Currencies are never merged.** Not in a total, not in a chart, not in a
  sentence. There is no exchange rate here — MXN 7,899.98 and USD 1,138.00 are two
  facts, not one.
- The tool does not know what today is: you pass the period.

Two judgments stay yours, because they are judgments:

- **A bill and its payment.** When `open_bills` shows a bill and the rows show a
  later payment to the same merchant that plainly paid it, call `money_report`
  again with `settled: [{"bill": "<bill id>", "payment": "<payment id>"}]`. The
  bill stops counting as due. It is remembered.
- **One transaction, two wordings.** When two rows are the same charge described
  differently (an order confirmation and the card alert for it), pass the weaker
  one's id in `skip`. Rows that are identical field for field are already counted
  once.

If it returns `needs_direction`, those rows were NOT counted — say so rather than
folding them in by hand.

## When unsure

Never estimate. After the body read, a receipt or payout with no legible amount
gets no `payment` at all and stands on its `summary`; a bill or statement keeps its
`payment` with `amount: null`. The money picture is built only from numbers you
actually saw.
