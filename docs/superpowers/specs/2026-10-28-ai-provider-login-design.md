# AI Mechanic: providers and sign-in (design)

Builds on `docs/superpowers/specs/2026-10-26-ai-mechanic-design.md` (stage 1) and on the code of branch `ai-mechanic-stage-1` (pull request smidley/Vynscope#1). Everything that document says still holds unless this one changes it.

## Intent

Scott pays for a ChatGPT plan already. Typing an API key is a chore and per-token billing is a second bill. The AI step should let him pick the AI provider he wants, sign in with the account he has, and have the mechanic run on that. Two providers also hedge against one vendor's pricing and policy.

The recon that shaped this (2026-10-28):

- Anthropic forbids it. Its legal page says: "Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route requests through Free, Pro, or Max plan credentials on behalf of their users. Moreover, developers may not collect, store, or intermediate Claude.ai credentials or session tokens." The server has enforced this since January 2026. Claude in Vynscope stays on a console API key.
- OpenAI allows it. "Sign in with ChatGPT" (DevDay, 2026-09-29) lets a user sign in to a third-party app with their ChatGPT account and, as a separate grant, let the app spend the plan's allowance. For open-source and locally hosted apps the flow is self-serve: dynamic client registration, no approval, no client secret. Paid or remotely hosted apps must complete an interest form.

## Goals

- A provider picker in AI settings, Anthropic or OpenAI, with the sign-in row and the model list following the picked provider (shape A of the 2026-10-28 mockups, Scott's choice).
- Anthropic signs in with the console API key exactly as today. OpenAI signs in with "Continue with ChatGPT" in a web sign-in; the app then runs on the owner's plan and no key exists anywhere.
- The mechanic behaves the same on either provider where the provider allows: the health check, the six read-only tools, the system prompt, the chat, activity lines, sources, chips, Stop, Try again, persistence.
- Sign-in works on the Mac and on the iPhone.
- The sign-in renews itself without the owner noticing; Sign out forgets everything.
- Honest usage: dollars on Claude, plan tokens on ChatGPT, and a plan that has run out is said out loud.

## Non-goals

- A Claude login. Forbidden by Anthropic.
- An OpenAI API key path. Scott has a plan; a key path can come later without changing this design.
- Other providers. The seam this design adds is where a third one would go, but none is built.
- Carrying a conversation from one provider to the other.
- More than one ChatGPT account on a device.
- The stage-3 product (backend, accounts, billing, App Store). One note for it below.

## Anti-goals

- Pooling, sharing, proxying or reselling the sign-in. Each person signs in as themselves on their own device; the app spends only that person's plan.
- A sign-in token anywhere but the Keychain, or in any log entry, file or error text.
- A sign-in that silently falls back to something else. If the plan grant is declined or the plan is exhausted, the chat says so.
- Any write to the car. The wire allow-list of stage 1 does not change.

## Constraints

### OpenAI: Sign in with ChatGPT (open-source flow)

Source: `developers.openai.com/siwc/token-sharing-open-source` and its sub-pages, read 2026-10-28. The builder re-reads them before implementing; what follows is what they said that day.

- Authorization endpoint `https://auth.openai.com/api/accounts/authorize`, token endpoint `https://auth.openai.com/api/accounts/oauth/token`. OAuth authorization code with PKCE (`code_challenge_method: S256`), fresh `state` and `nonce` per attempt, both validated on return.
- First sign-in registers the app: `client_id=dynamic_agent_client`, `agent_name_hint=Vynscope` (first sign-in only), `ext_agent_host_id` (an opaque `urn:uuid:…` generated once per device before the first sign-in and kept), `response_type=code`, `scope=openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`, `resource=https://api.openai.com/v1`. The callback carries `code`, `scope`, `state` and the issued `client_id` (`oaiapp_…`), which the app keeps and uses on every later sign-in, omitting `agent_name_hint`, optionally sending `id_token_hint` and `login_hint`.
- The redirect goes to an HTTP loopback listener the app starts before opening the browser: `http://127.0.0.1:<port>/auth/callback`. `127.0.0.1`, never `localhost`; the scheme, host and path never change, only the port may; the same URI is used in the authorization request and the code exchange. `error=access_denied` ends the attempt without an exchange.
- Code exchange: form-encoded `authorization_code` grant with `client_id`, `code`, `code_verifier`, `redirect_uri`, `resource`. No client secret. `invalid_grant` means start over with the issued client id.
- The ID token is validated as the doc says: signature against OpenAI's published JWKS, issuer, audience equal to the issued client id, expiry, nonce. The validated `sub` is the account identity. The granted scopes must include `chatgpt.tokens.use.direct` before any inference; a valid ID token alone does not grant plan usage.
- Access tokens last one hour (`expires_in: 3600`); with `offline_access` the exchange returns a refresh token that lasts thirty days, and every refresh returns a replacement. Refresh: form-encoded `POST` to the token endpoint with `grant_type=refresh_token`, the issued `client_id` (never `dynamic_agent_client`), the saved `refresh_token` and `resource=https://api.openai.com/v1`, no `scope`; refreshes are serialised; after one, the access token, expiry, scopes and rotated refresh token are replaced together. `invalid_grant`, `invalid_refresh_token`, `token_expired`, `refresh_token_expired`, `refresh_token_invalidated` and `refresh_token_reused` mean the tokens are unusable: clear them and sign in again with the saved client id. A transient network or 5xx failure clears nothing.
- Sign out: look up `revocation_endpoint` in `https://auth.openai.com/.well-known/openid-configuration` and `POST` form-encoded `token=<refresh token>`, `token_type_hint=refresh_token`, `client_id=<issued id>`; an empty 200 means revoked (already-invalid tokens included); network or 5xx failures are retried with backoff. Then the access, refresh and ID tokens are deleted. The issued client id, the host id and the account-to-client mapping are kept, so a later sign-in reuses the registration and shows no consent screen; revoking never deletes the registered client. If revocation cannot be confirmed, the tokens are cleared anyway and the owner is told that remote revocation was not confirmed and that the app can be disconnected in ChatGPT Settings.
- Credential protection: tokens live only in protected local storage, never in browser storage, source control, logs, analytics or URLs; the ID token goes only to OpenAI's authorization endpoint as `id_token_hint`, and an authorization URL that carries it is redacted from the Log. The host id is an opaque identifier, not a credential.
- Errors with a prescribed recovery (the errors-and-recovery page): `subscription_sharing_usage_limit_exceeded` (429): pause requests on the plan and link to `https://chatgpt.com/settings/usage`, without assuming the whole plan is empty (an app-specific cap also raises it) and without inferring a reset time. `subscription_sharing_usage_unavailable` (503) and `subscription_sharing_user_unavailable` (503): keep the credentials and retry later with bounded backoff. `subscription_sharing_unsupported_capability` (400): read `error.param`, remove the unsupported tool, input, model or service-tier override, and never resend the same body. `subscription_sharing_user_not_eligible` (403): explain the restriction, no retry and no new OAuth loop. `subscription_sharing_invalid_user` (401): ask for a new sign-in only after a confirmed revocation or a terminal refresh error. `invalid_client`: a client configuration problem.
- UI guidelines (the ui-ux-guidelines page): the sign-in button says "Continue with ChatGPT" with the white ChatGPT logo in one of OpenAI's approved formats; "Using ChatGPT plan" with a "Manage usage" link to `https://chatgpt.com/settings/usage` sits near the composer or the model selector whenever requests use the plan; a one-time welcome after the first sign-in with plan usage, titled "You're using your ChatGPT plan", saying that eligible AI requests in the app use the plan and that usage can be managed in ChatGPT settings, dismissed with "Got it"; the usage-limit state is titled "Usage limit reached" with the body "Review your plan or this app's limit in ChatGPT settings." and "Manage usage" as the primary action, as a modal or a compact message.
- Stored per issued client id and identity: `email`, `issuer`, `subject`, `client_id`, `ext_agent_host_id`, `id_token`, `access_token`, `refresh_token`, `token_type`, `expires_in`, granted `scopes`, `saved_at`. In Vynscope this record lives in the Keychain (my call; the doc asks for an owner-only file and never a log or a commit, and the Keychain is the stronger form of that on both platforms).
- The sign-in button reads "Continue with ChatGPT" and follows OpenAI's branding guidelines.
- Inference: `POST https://api.openai.com/v1/responses` with `Authorization: Bearer <access token>`, never ChatGPT's `backend-api`. Every request sets `store: false` and `stream: true`, sends `input` as an array and the system prompt as `instructions` (explicit system message items are rejected), and omits `background`, `conversation`, `max_output_tokens`, `max_tool_calls`, `metadata`, `moderation`, `multi_agent`, `prompt`, `prompt_cache_retention`, `safety_identifier`, `temperature`, `top_logprobs`, `top_p`, `truncation` and `user`. `previous_response_id` is not available, so the whole history is sent each time, as it already is on Claude. Function tools are supported (grouped in namespaces or supplied via `additional_tools`, per the doc; the builder confirms the exact shape). Web search is "subject to model and account/workspace policy". Image generation, file search, Code Interpreter, computer use, hosted MCP and `tool_search` are not available. Models: whatever `GET https://api.openai.com/v1/models` lists for the signed-in account (`visibility == "list"` for display).
- A finished request is one that reached `response.completed`. Plan limits arrive as `response.failed` with code `subscription_sharing_usage_limit_exceeded` or `subscription_sharing_usage_unavailable`, possibly after streaming has started.
- Eligibility: "open-source and locally hosted apps". Vynscope runs on the owner's own device and its source is public; an MIT license file makes the open-source part plain (my call, Scott did not object). Users can cap each app's weekly usage in ChatGPT settings; the app does not get told the cap.

### Anthropic

Unchanged from stage 1: the console API key in the Keychain, `POST https://api.anthropic.com/v1/messages` with the pinned headers and parameters. No sign-in of any kind.

### Platform

- Swift 6, strict concurrency, MainActor default isolation, no third-party packages. ID-token signature checks use Security.framework or CryptoKit; the builder picks by the algorithm OpenAI's JWKS advertises.
- Mac: "Continue with ChatGPT" opens the owner's default browser (`NSWorkspace`), the loopback listener catches the redirect and answers a small "You can close this page" document, and the app comes to the front with "Signed in as <email>".
- iPhone: the same sign-in in an `SFSafariViewController` sheet inside the app, so the app stays in the foreground and its listener stays alive to catch the redirect; the app dismisses the sheet when the callback arrives. (My call: OpenAI's flow is written for computers and names no mobile path; a background listener would be killed while the owner signs in.)
- No test touches the network. The OAuth exchange, refresh and the Responses stream run against the existing fake transport with recorded fixtures, as the Claude client does.

## Decided: the screens

### Settings

From a gear on the AI step, as today. Top: a Provider picker, Anthropic or OpenAI. Under it the sign-in row of the picked provider only:

- Anthropic: the API key field, Save, "A key is saved" / "No key saved", Remove key, exactly as today.
- OpenAI: "Continue with ChatGPT" in OpenAI's button format. After sign-in: "Signed in as <email>" and Sign out. Sign out revokes and clears the tokens as the constraints say and keeps the registration; if revocation was not confirmed the row says so and names ChatGPT Settings as the place to disconnect the app. If the account signed in but declined the plan grant: "Signed in as <email>, but Vynscope may not use your ChatGPT plan"; because a returning sign-in shows no consent screen, the row's hint says to disconnect Vynscope in ChatGPT Settings and sign in again. An account that is not eligible for plan sharing (`subscription_sharing_user_not_eligible`) gets the restriction explained and the advice to pick Anthropic. Errors from the sign-in (the browser denied, the exchange failed, the token could not be renewed) show in red under the row, cleared by the next success, as key errors do today. One ChatGPT account per device; a second account means signing out first (my call; OpenAI supports several registrations per host, Vynscope does not need them).
- The first sign-in with the plan grant shows OpenAI's one-time welcome ("You're using your ChatGPT plan", "Got it") once, as a sheet over Settings; later sign-ins do not.

Then, for the picked provider: Model (Anthropic: Opus 5.5, Sonnet 5.5, Haiku 5.5 with their prices as today; OpenAI: the list the account can reach, refreshed when the sheet opens, with the account's newest general model as the default, my call), Effort (Anthropic only; OpenAI's reasoning setting is left to the builder, see below), the price table (Anthropic only), the privacy sentence naming the picked provider, Clear conversations.

Switching provider changes nothing until a sign-in exists for it; the AI step then shows the stage-1 notice with the provider's name ("Sign in to ChatGPT in Settings to switch on the AI mechanic." / the existing key notice).

### The AI step and the chat

Unchanged, with three differences:

- A conversation belongs to the provider it started on. Each car keeps at most one conversation per provider on disk (the file name carries the provider); switching provider shows that provider's conversation for the car, or runs a fresh health check if there is none. The other provider's conversation is kept for switching back. New conversation and Clear conversations act on the picked provider's files.
- The usage line: on Claude, as today. On ChatGPT: tokens in and out, the search count, and "on your ChatGPT plan" in place of the dollars; the Total counts only the Claude turns' dollars and says "on your ChatGPT plan" when there are none. While the picked provider is OpenAI, a caption "Using ChatGPT plan · Manage usage" sits above the input bar, the link opening `https://chatgpt.com/settings/usage`, as OpenAI's guidelines ask. When a turn ends in `subscription_sharing_usage_limit_exceeded`, the chat shows the compact usage-limit message under the question, "Usage limit reached. Review your plan or this app's limit in ChatGPT settings.", with "Manage usage" as the primary action and Try again second (the limit may be the app's weekly cap rather than the plan, and it resets without telling the app); no further plan request is sent until the owner tries again. `subscription_sharing_usage_unavailable` is retried like a 529, then shows "ChatGPT couldn't check your plan's usage; try again in a moment".
- Web search is not guaranteed on the plan. When a request is refused with `subscription_sharing_unsupported_capability` and `error.param` names the web search tool, the client remembers that web search is unavailable for that model on this account, re-sends the request without the web tool and with the prompt variant that says the mechanic has no web access and must say so when a question needs it, and the chat shows one line, "Web search isn't available on <model> with your plan; answering from the car's data only", above the answer; that model's later turns carry no web tool and no such line. If `error.param` names anything else, the turn fails with the API's message and the owner picks another model. Never the same body twice. (My call: a mechanic without the web is still worth having for a fault read; the line in the chat keeps the stage-1 rule that no fallback is silent, and without the tool there is no web claim to cite.)
- Sources: on Claude, search citations and fetched pages as today. On ChatGPT, the URL citations the Responses API attaches to the answer; there is no page fetch on that side, so "Fetched …" activity lines only ever appear on Claude.

Every turn's record remembers its provider and model, so a saved conversation renders the same after a relaunch.

## Decided: what the mechanic can do

Unchanged. The same six read-only tools with the same schemas (converted to the provider's declaration shape), the same health check and context JSON, the same system prompt with one sentence that names the provider's web tools as they exist on that side, the same read cap and round cap, the same Stop between tool calls.

## Code shape

In `BMWCodingCore`, a provider-neutral seam at the Mechanic boundary: the mechanic hands a client its tool declarations (name, description, JSON schema) and the system prompt, runs the tool calls the client reports, and receives text, activity blocks, usage and the stop state back. Behind the seam, two clients: the existing `ClaudeClient`, and an `OpenAIClient` for the Responses API over the same `Transport` and SSE parser (the Responses stream is SSE with `event:` lines; the events to handle are at least `response.created`, `response.output_item.added` and `.done` for `function_call`, `web_search_call` and `reasoning` items, `response.output_text.delta`, `response.function_call_arguments.delta` and `.done`, `response.completed` with `usage`, `response.incomplete`, `response.failed`, `error`). The tool loop on OpenAI: `function_call` items are run and answered with `function_call_output` items carrying the `call_id`, appended to `input` with the full history, and the model is asked again, up to the same round cap. Each conversation is stored in its provider's wire shape; nothing converts between them. A `ChatGPTSignIn` (or similar) type owns registration, the loopback listener, the exchange, validation, refresh and the Keychain record; the app's views only call "sign in", "sign out" and "current token". A small `Provider` enum threads through settings, the conversation store, the turn records and the usage line.

Tests, all against the fake transport: the authorization URL built for a first and a later sign-in, the callback parsing with a wrong `state`, an `access_denied`, a missing issued client id, the exchange request body, a refresh that rotates the token and a refresh error that clears it, the sign-out revocation request and the unconfirmed case, the plan-grant check, the Responses stream assembler from fixtures (text, a function call, a web search call, `response.completed` usage, `response.failed` with each plan code), the OpenAI tool loop with two rounds and the cap, the unsupported-capability resend without the web tool and the failure when the param names the model, the per-provider conversation files, and the usage line text in both modes. No test calls OpenAI or Anthropic.

## Stage 3 note

The self-serve registration is for open-source and locally hosted apps. A paid or App Store build with a backend goes through OpenAI's interest form and a registered client id, and a ChatGPT plan can never be used on a user's behalf from a server. The product version keeps "Continue with ChatGPT" only if OpenAI's program for such apps allows it then; otherwise the backend key path of the stage-3 sketch stands.

## Left to the builder

- The exact Responses request body for tools (namespaces versus `additional_tools`), strict function schemas, and whether `include: ["reasoning.encrypted_content"]` is needed and allowed with `store: false` so reasoning carries across the tool rounds of one turn.
- How to pick "the account's newest general model" from the model list, and what the OpenAI effort control is, if any (a `reasoning.effort` field, or nothing).
- The loopback server (Network framework), the ephemeral port, the page it answers with, and how the Mac app comes to the front.
- The SwiftUI wrapping of `SFSafariViewController` and what happens if the owner dismisses the sheet before signing in.
- The JWKS fetch and signature check, and how long the keys are cached.
- Where the renewal happens (before each request when the token is within a minute of expiry, my suggestion) and what the chat shows when a renewal fails (sign in again, never a key).
- The Keychain record layout for the sign-in and the per-device host id.
- How OpenAI's usage object maps onto the turn record, and the price table's absence on that side.
- Prompt wording where it names the provider's tools.

## What Scott verifies

On the Mac and the iPhone, after stage 1's Task 11: pick OpenAI, Continue with ChatGPT, sign in, approve the plan grant, see the welcome once and then "Signed in as"; a health check and a question run on the plan with the usage line and the "Using ChatGPT plan" caption saying so; Sign out, then confirm in ChatGPT Settings that Vynscope's session is gone and the app is still listed; disconnect Vynscope in ChatGPT Settings, sign in again and decline the plan grant to see the "may not use your ChatGPT plan" row; a forced token renewal (wait an hour, or change the clock); switch back to Anthropic and see the Claude conversation for the car untouched; the app's weekly cap in ChatGPT settings set low enough to hit "Usage limit reached" mid-turn, and Manage usage opening the settings page; a model that cannot search, if the account has one, showing the "Web search isn't available" line; and the Log carrying no token, no authorization URL and no key.
