# Provider source audit

Fenestra uses the MIT-licensed `CodexBarCore` provider pipeline pinned to
CodexBar revision `e810f7e040d5f2200b96086b8258acbb75028ce9` (2026-06-28).
This keeps credential discovery, fallback ordering, endpoint validation, and
response parsing on the same tested implementation.

`Automatic` is the default source. A user can enable each provider, select any
source mode the descriptor supports, choose automatic/manual/off browser
sessions, and set provider credentials or routing fields in Settings.
API keys, secret keys, and manual cookie headers are stored in the macOS
Keychain.

| Provider | Automatic usage source |
| --- | --- |
| Codex | OAuth API → Codex CLI RPC/PTY |
| OpenAI | Admin API key → legacy credit balance |
| Azure OpenAI | API key + endpoint + deployment probe |
| Claude | Admin API when configured; otherwise OAuth → Claude CLI → web session |
| Cursor | Browser/manual cookies → stored WebKit session |
| OpenCode | Web dashboard session |
| OpenCode Go | Web dashboard → local SQLite |
| Alibaba Coding Plan | Web console session → API key |
| Alibaba Token Plan | Bailian web session |
| Droid / Factory | Browser cookies → stored/local WorkOS tokens |
| Gemini | Gemini CLI OAuth credentials |
| Antigravity | Local/managed CLI probe → Google OAuth |
| GitHub Copilot | GitHub OAuth/config token |
| Devin | Browser local storage or manual bearer token |
| z.ai | API token |
| MiniMax | Coding Plan web session or API token |
| Manus | Browser/manual `session_id` |
| Kimi | Kimi Code API key → web session |
| Kilo | API token → CLI session |
| Kiro | `kiro-cli /usage` |
| Vertex AI | Google ADC / gcloud OAuth |
| Augment | `auggie` CLI → browser session |
| JetBrains AI | Local IDE quota XML |
| Kimi K2 | API key |
| Moonshot | API key |
| Amp | Local CLI → access-token API → browser session |
| T3 Chat | Web tRPC session |
| Ollama | Cloud API key or web session |
| Synthetic | API key |
| Warp | API token |
| OpenRouter | API token |
| ElevenLabs | API key |
| Windsurf | Browser local storage → local SQLite |
| Zed | Zed Keychain session |
| Perplexity | Browser/manual session |
| Xiaomi MiMo | Browser session |
| Doubao | API key probe |
| Sakana | Web session |
| Abacus AI | Browser session |
| Mistral | Console browser session |
| DeepSeek | API key |
| Codebuff | API token → local login credentials |
| Crof | API key |
| Venice | API key |
| Command Code | Web billing session |
| StepFun | Username/password or Oasis token |
| AWS Bedrock | AWS profile or access/secret keys |
| Grok | `grok agent` JSON-RPC → browser session |
| GroqCloud | API key |
| LLM Proxy | API key + base URL |
| LiteLLM | API key + base URL |
| Deepgram | API key + optional project |
| Poe | API key |
| Chutes | API key |

## Validation

- Fenestra tests assert an exact one-to-one mapping for all 54 provider IDs.
- Every descriptor’s supported source modes are compared with the Settings UI.
- Every provider builds a fetch settings snapshot and environment overlay.
- API, AWS, Keychain persistence, history, cadence, and toggle paths have local
  regression tests.
- CodexBar’s 4,712 upstream tests were exercised. The 43 core/Linux security
  tests passed. The complete 4,669-test macOS run exposed only deadline tests
  starved by full-suite parallelism; all 74 affected tests passed when rerun as
  their seven suites.
- Live local smoke tests returned valid data for the four configured accounts:
  Claude (`web` fallback), Codex (`oauth`), Cursor (`web`), and Antigravity
  (`cli`).

Live validation of a provider still requires that provider’s account,
credential, CLI, or browser session. Fixture tests validate parsing and
fallback behavior without making synthetic requests against unconfigured
accounts.
