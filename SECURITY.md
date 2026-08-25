# Security policy

dum-tum runs commands in the user's interactive shell and can send contextual data to a configured AI provider. Security reports are taken seriously.

## Reporting a vulnerability

Please use [GitHub private vulnerability reporting](https://github.com/arjunagi-a-rehman/dum-tum/security/advisories/new). Include the affected version, operating system, shell and version, provider, reproduction steps, and expected impact.

Do not include live API keys, access tokens, passwords, or other credentials. Replace them with clearly marked test values.

## Supported versions

Security fixes target the latest npm release and the current `main` branch. Users should update with:

```bash
npx dum-tum@latest
exec zsh          # or: exec bash
```

## Data and trust boundaries

- Local fuzzy matching does not contact an AI provider.
- AI requests can include OS and shell, cwd, directory entries, project scripts or Make targets, aliases, and user or failed-command input.
- Known secret shapes are redacted, but no redaction system is complete.
- API keys and HTTP bodies are sent to curl through stdin or files rather than command arguments.
- Prompts passed to some local CLI providers may be visible to other local users in the process table while the provider runs.
- AI suggestions require confirmation before execution.

Set `FX_PROVIDER=none` for local-only operation. Set `FX_AI_ON_FAIL=0` to prevent automatic AI handling of eligible failed commands.
