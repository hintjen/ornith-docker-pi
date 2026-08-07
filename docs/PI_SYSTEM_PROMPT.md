# Pi's System Prompt — where it lives, what it says, how to change it

Reference for the **base system prompt** the Pi coding agent (`@earendil-works/pi-coding-agent`)
sends to the Ornith server. Verified against **pi 0.80.2** (the version this repo pins).

> TL;DR — there is **no server-side system prompt**. `llama-server`'s `--system-prompt` flag is
> a no-op for the OpenAI `/v1/chat/completions` API (none of the `tools/server/` code reads it).
> The system prompt comes from the **client (Pi)**, assembled at runtime.

---

## Where it lives

Pi builds the prompt dynamically in `buildSystemPrompt()`:

- Installed file: `…/@earendil-works/pi-coding-agent/dist/core/system-prompt.js`
- Source on GitHub: `earendil-works/pi` → `packages/coding-agent/src/core/system-prompt.ts`

View the authoritative copy for your installed version:

```bash
# in the container
docker exec ornith cat /opt/ornith/node/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/system-prompt.js

# bare-metal / client install (Node under ./build/node)
cat build/node/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/system-prompt.js

# or locate it anywhere
find / -path '*pi-coding-agent/dist/core/system-prompt.js' 2>/dev/null
```

---

## The base prompt (the fixed core)

When you don't pass `--system-prompt`, Pi uses this core block (tool lines and guidelines are
filled in from the enabled tools):

```
You are an expert coding assistant operating inside pi, a coding agent harness. You help users
by reading files, executing commands, editing code, and writing new files.

Available tools:
- read: <one-line snippet>
- bash: <one-line snippet>
- edit: <one-line snippet>
- write: <one-line snippet>

In addition to the tools above, you may have access to other custom tools depending on the project.

Guidelines:
- <tool-dependent guidelines>
- Be concise in your responses
- Show file paths clearly when working with files

Pi documentation (read only when the user asks about pi itself, its SDK, extensions, themes,
skills, or TUI):
- Main documentation: <readme path>
- Additional docs: <docs path>
- Examples: <examples path> (extensions, custom tools, SDK)
- When reading pi docs or examples, resolve docs/... under Additional docs and examples/... under Examples
- When asked about: extensions, themes, skills, prompt templates, TUI components, keybindings,
  SDK integrations, custom providers, adding models, pi packages — read the matching docs/*.md
- When working on pi topics, read the docs and examples, and follow .md cross-references before implementing
- Always read pi .md files completely and follow links to related docs
```

Defaults worth noting:
- Default tools when none are restricted: `read, bash, edit, write`.
- Two guidelines are **always** appended: *"Be concise in your responses"* and *"Show file paths
  clearly when working with files"*. Tool-specific ones are added conditionally (e.g. *"Use bash
  for file operations like ls, rg, find"* when only `bash` is available).

---

## How the full prompt is assembled (order)

`buildSystemPrompt()` concatenates, in this order:

1. **Core block** above — *or* your `--system-prompt <text>` verbatim if provided (it **replaces**
   the core; the steps below still run).
2. **`--append-system-prompt`** text/file contents (repeatable).
3. **Project context files** — wrapped in `<project_context>` / `<project_instructions path="…">`.
4. **Skills** — appended only if the `read` tool is enabled.
5. **Footer** — two lines added last:
   ```
   Current date: YYYY-MM-DD
   Current working directory: <cwd>
   ```

---

## See the *fully rendered* prompt

The static source shows the template; to see the exact text sent (tools/date/cwd filled in):

```bash
pi --export ~/.pi/agent/sessions/--<cwd>--/<session>.jsonl out.html   # includes the system message
# or just read the session .jsonl in ~/.pi/agent/sessions/
```

---

## Changing it

| Goal | How |
|---|---|
| Add rules, keep the coding agent | `pi --append-system-prompt "<text>"` or `--append-system-prompt <file>` (repeatable) |
| Replace the whole core prompt | `pi --system-prompt "<text>"` (you lose the built-in agent guidance) |
| Per API request (no Pi) | include a `{"role":"system","content":"…"}` message in `/v1/chat/completions` |
| Project-wide instructions | put them in a context file Pi loads (appears under `<project_context>`) |

The `pi-ornith` / `pi-remote` wrappers pass these flags straight through, e.g.
`docker exec -it ornith pi-ornith --append-system-prompt /work/HOUSE_RULES.md`.

> Remember: setting `--system-prompt` / `--system-prompt-file` on **`llama-server`** does nothing —
> the prompt must be set on the Pi client (or per request).
