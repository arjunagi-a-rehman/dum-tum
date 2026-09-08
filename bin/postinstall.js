#!/usr/bin/env node
console.log(`
dum-tum is installed, but the shell helper is not set up yet.

To finish installation, run:

  npx dum-tum

Other options:

  npx dum-tum --provider openrouter                           enter a key in the hidden prompt
  npx dum-tum --provider opencode --model anthropic/claude-sonnet-4
  npx dum-tum --uninstall

For non-interactive installs, set the matching provider environment variable first
(OPENROUTER_API_KEY, OPENAI_API_KEY, ANTHROPIC_API_KEY, or GEMINI_API_KEY).

Documentation: https://github.com/arjunagi-a-rehman/dum-tum#readme
`);
