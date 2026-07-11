# Prompt fragments

Drop optional Markdown files here to **append** extra instructions to the triage
agents' system prompts. Fragments are *added on top of* each agent's built-in
instructions and the email_triage skill — they never replace them.

Files (all optional):

| File | Appended to |
|------|-------------|
| `common.md` | every agent (Apple Mail, Gmail, HEY, and the merge agent) |
| `apple_mail.md` | the Apple Mail agent only |
| `gmail.md` | the Gmail agent only |
| `hey.md` | the HEY agent only |
| `merge.md` | the merge agent only |

Example — create `gmail.md` with:

```
Flag anything from my landlord or building management as Action, even if it
looks like a newsletter.
```

Changes take effect on the next run. Override this directory's location with
`NEXO_MAIL_PROMPTS_DIR`.
