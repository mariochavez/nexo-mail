# Docker sandboxes for data pipelines (Python/pandas/ninja, or similar)

A worked pattern for: running a custom-image container sandbox for a
scripted data pipeline (Python + pandas + ninja is the example; the pattern
is the same for any toolchain), keeping transient files usable across
multiple script steps, and — optionally — letting an agent drive the
pipeline with a skill guiding it, rather than hardcoding every step.

Three separate, composable pieces. Don't conflate them:

1. **The image** — a normal Dockerfile, entirely outside Nexo.
2. **The Workflow** — `sandbox :docker` + `stage`/`artifact` for the
   transient-files question.
3. **The Skill** (optional) — reference material for an agent driving the
   pipeline, not new capability.

## 1. The image (yours, not Nexo's)

Nexo's `Container` sandbox is shell-out-only — no client gem, no Compose,
**no image builder** (that's a direct quote from the class's own doc
comment). It only ever references an image tag you already built and
pushed:

```dockerfile
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends ninja-build \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir pandas
WORKDIR /workspace
```

```sh
docker build -t your-registry/nexo-pandas:latest .
docker push your-registry/nexo-pandas:latest
```

**Caveat worth knowing up front:** the sandbox's default `network: :none`
means anything network-dependent (`pip install`, `apt-get`) has to happen at
image-build time, never inside a running sandbox. A script that genuinely
needs runtime egress needs an explicit `network:` override on the `sandbox`
macro — never a default you'd get by accident.

## 2. Transient files — two different lifetimes, two different mechanisms

**Within one run** (a script writes a CSV, the next script reads it, ninja
reads both): the container's `cwd` (default `/workspace`) is writable even
under the hardened `readonly_rootfs: true` posture — Nexo mounts an
ephemeral `tmpfs` there specifically for tool scratch space. As long as it's
the same `Sandbox` instance driving every step, files just sit there between
calls.

**Across runs, or if files need to survive the container being torn down**
— use `stage`/`artifact` (Workflow-level) and `binds:`/`reconnect:`
(Container-level):

```ruby
class PandasPipeline < Nexo::Workflow
  sandbox :docker,
    image: "your-registry/nexo-pandas:latest",
    binds: { "/data/nexo-pandas-scratch" => { to: "/workspace/persisted", mode: :rw } },
    name: "nexo-pandas-pipeline", reconnect: true   # same container reused, not fresh per run

  def call(payload)
    stage(payload[:files])                                   # input CSVs into the sandbox first
    sandbox.write("/workspace/build.ninja", payload[:ninja])  # or bake the .ninja file into the image
    sandbox.shell("python transform.py")
    sandbox.shell("ninja -f build.ninja")
    artifact("report.csv", content: sandbox.read("/workspace/out/report.csv"))
  end
end

run = PandasPipeline.run(files: [{ path: "input.csv", content: raw_csv }], ninja: ninja_build_text)
run.artifacts.first["content"]   # readable back from the run record, independent of the container
```

What each piece is actually for:

- **`binds:`** is the durable option — a real host directory, survives the
  container being removed entirely. Binds default to `:ro`; the
  `{ to:, mode: :rw }` form (shown above) is what makes one writable.
- **`name:` + `reconnect: true`** reuses the *exact same* container across
  separate `.run`/`.resume` calls instead of spinning up a throwaway one
  each time. Useful if the tmpfs scratch itself should persist across a
  suspend/resume without going through `binds:` — but `binds:` is the safer
  bet if the container could ever be pruned or the host restarted, since
  tmpfs is memory-backed and doesn't survive that.
- **`artifact(name, content:)`** is the one that matters most for handing
  files to a *skill*: it writes to `/artifacts/<name>` **inside the
  sandbox** (so a later step in the same run can `sandbox.read` it) **and**
  records it on `run.artifacts` — durable, queryable independent of the
  container's lifecycle. A skill's instructions should point the model at
  this path/convention rather than a location it has to guess.

## 3. Letting an agent decide *which* script to run

If the choice of script (not just its execution) needs a model's judgment,
drive the pipeline through `run_agent` rather than giving the agent its own
`:docker` sandbox macro. Under `run_agent` the agent inherits the
**workflow's** sandbox — its own `sandbox` macro is ignored in that mode —
so it's the same container, same persisted files, same `/artifacts`:

```ruby
class DataAnalyst < Nexo::Agent
  model       ENV.fetch("NEXO_MODEL")
  permissions :auto        # :shell capability needed for python/ninja
  skills      :pandas_pipeline
end

class AnalyzePipeline < Nexo::Workflow
  sandbox :docker, image: "your-registry/nexo-pandas:latest",
    binds: { "/data/nexo-pandas-scratch" => { to: "/workspace/persisted", mode: :rw } }
  agent DataAnalyst

  def call(payload)
    stage(payload[:files])
    resp = run_agent("Clean input.csv with pandas, then run the ninja build to produce report.csv")
    artifact("report.csv", content: sandbox.read("/workspace/out/report.csv"))
    { content: resp.content }
  end
end
```

`app/skills/pandas_pipeline/SKILL.md` is where the actual reusable
`.py`/`.ninja` script *text* belongs — reference material the agent reads
through its own gated `ReadFile` tool, not new capability (see the main
skill's "Assuming `skills :name` widens what an agent can do" pitfall — the
same rule applies here):

```markdown
---
name: pandas_pipeline
description: How to run this project's pandas cleaning step and ninja build.
---

# Pandas + ninja pipeline

Input lands at /workspace/input.csv (staged by the workflow).
Run `python transform.py`, then `ninja -f build.ninja`.
Final output belongs at /workspace/out/report.csv, then call artifact() on it.

## references/transform.py
...
## references/build.ninja
...
```

## Quick checklist for adapting this to a different toolchain

- [ ] Dockerfile has every binary the scripts need, built and pushed *before* any sandbox runs it
- [ ] Decide: same-run scratch (do nothing extra) vs. cross-run durability (`binds:`) vs. same-container reuse (`reconnect: true`)
- [ ] Every step that should survive the container's teardown goes through `artifact()`, not just a sandbox path
- [ ] If an agent is choosing scripts, drive it via `run_agent` so it shares the workflow's sandbox rather than getting its own
- [ ] `network:` stays `:none` unless a script genuinely needs runtime egress — get everything installed at image-build time instead
