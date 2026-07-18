---
title: "Durable workflows and human approval"
date: 2026-07-17
category: desarrollo
tags: [ruby, ai, nexo, workflows, durable, approval]
series: "Building an email agent with Nexo"
part: 9
---

# Durable workflows and human approval

Everything so far has been read-only, and I intend to keep the shipped tool that
way. But the question comes up the moment anyone sees the digest: could it archive
the Noise for me, or draft a reply? Those are write actions against a real inbox,
and I would not let a language model take them unattended. I would want to see what
it plans to do and approve it first.

That is a specific pattern, and Nexo has a primitive for it. A workflow can pause,
durably, and wait for a human, then continue exactly where it stopped, even in
another process. This post is about those primitives and the `:approve` permission
mode. The tool stays read-only; this is the path it would take if it grew a hand.

## Suspending and resuming a run

Three pieces make a workflow durable, and they build on the run record from
[Part 4](04-workflows.md) rather than adding an engine.

`checkpoint(name) { ... }` runs its block once and stores the result under `name` in
the run's state. On resume, it returns the stored value without running the block
again. You wrap expensive or already-paid-for work in it.

`suspend!(reason:)` marks the run suspended, which is a normal outcome, not a
failure, and returns to the caller. `Workflow.run` does not raise; it hands back a
run whose status is `suspended`.

`Workflow.resume(run_id, input)` continues a suspended run, and the input you pass
arrives inside `#call` as `resume_input`.

Here is the shape, using a hypothetical archive step:

```ruby
class ArchiveNoise < Nexo::Workflow
  def call(payload)
    digest = checkpoint(:load) { load_digest(payload[:run_id]) }   # runs once

    unless resume_input[:approved]
      emit(:awaiting_approval, count: digest["noise_count"])
      suspend!(reason: "approve archiving #{digest["noise_count"]} messages")
    end

    checkpoint(:archive) { archive_noise!(digest) }
    { archived: true }
  end
end
```

```ruby
run = ArchiveNoise.run(run_id: 42)   # status "suspended", nothing archived yet
# a person reads run.suspend_reason, decides, and:
ArchiveNoise.resume(run.id, approved: true)   # :load did NOT run again; :archive runs
```

The first run reaches the `suspend!` and stops with nothing archived. When it
resumes with approval, the `:load` checkpoint returns its stored value instead of
re-loading, and the `:archive` checkpoint runs. The human sat in the middle of a
running job, and the job waited without holding a process open.

## Approval at the tool level

The example above gates the workflow explicitly. Nexo also has a finer version that
gates at the moment an agent tries to use a capability, through the `:approve`
permission mode.

When a workflow drives an agent whose permissions are `:approve`, and that agent
reaches for a gated capability mid-loop, the gate raises `Nexo::ApprovalRequired`.
The workflow catches it, records the pending call in the run's state under a
reserved key, and suspends the run. Resuming with `approved: true` threads the
decision back through the same gate, so the tool call proceeds. Resuming with
`approved: false` denies it, the tool receives an error, the model adapts, and the
run still finishes.

So an archiver agent under `:approve` would run, decide which messages to archive,
and the instant it called the archive tool the run would suspend with the pending
call recorded. A human could see exactly what it intended to do, to which messages,
before anything happened.

This is where the distinction between two of Nexo's signals matters.
`Permissions::Denied` means "no, work around it," and tools rescue it into an error
the model sees. `ApprovalRequired` means "pause and ask," and tools must not rescue
it; it has to propagate up to the workflow so the run can suspend. They look
similar and behave oppositely.

## Resume is re-entry, not replay

The one thing to internalize about durable workflows is how resume works. It does
not replay a recorded log of steps. It calls `#call` again from the top. Everything
outside a `checkpoint` runs again; only the checkpoints return their stored results.

That has direct consequences for how you write `#call`. Any step that is expensive,
or that has a side effect you do not want to repeat, must be inside a checkpoint. A
non-idempotent action placed before the approval gate will run on the first pass and
again on resume. So approval gates go early, before you have done anything you would
not want to do twice. Idempotency is your responsibility; Nexo gives you the
checkpoint to make a step run-once, but it does not guess which steps need it.

There is a smaller sharp edge: a crash inside a checkpoint re-runs that checkpoint,
so the guarantee is at-least-once, not exactly-once. For a step that must never run
twice, that matters, and you handle it the way you would handle any at-least-once
job, with an idempotency key.

## What this needs to actually persist

The durable behavior is only as durable as the store behind it. In plain Ruby, with
the in-memory run store, a suspended run lives in the process, so you can resume it
only in that same process, which is fine for a script or a test. To suspend in one
process and resume in another, for example suspend from a web request and resume
from a background job after someone clicks approve, you need the ActiveRecord run
store and ActiveJob, which is Rails territory and the subject of the last post.

## Why the shipped tool stays read-only

I want to be clear that `nexo_mail` does not ship the archive action. It reads and
reports, and that is the whole product. The reason to cover this here is that
read-only is a choice, not a limitation of the design, and the design has a clean,
auditable path to a write action when one is worth adding. The tool does have one
destructive operation, pruning old run snapshots, but that is a bounded file
operation exposed as a tool the agent calls, not a mutation of your mail, so it does
not need an approval gate. When the day comes that a write against the inbox earns
its keep, `:approve` plus suspend and resume is how it would be gated, and a human
would always see the plan first.

## What will trip you up

Put approval gates before side effects. Resume re-runs everything outside a
checkpoint, so anything non-idempotent before the gate happens twice.

Wrap expensive and side-effectful steps in checkpoints. That is the only thing that
makes a step run once across a suspend and resume. Nexo will not infer it.

Do not rescue `ApprovalRequired` in a tool. It is a control signal that must reach
the workflow to suspend the run. It is the opposite of `Denied`, which you do
rescue.

Cross-process resume needs a real store. The in-memory store resumes only in the
same process. Suspending from a web request and resuming from a worker needs the
ActiveRecord store and ActiveJob.

Next: [Part 10, shipping the tool as a CLI, a gem, and a Rails job](10-shipping.md).
