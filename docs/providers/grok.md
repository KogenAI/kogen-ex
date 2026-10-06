# Grok provider research and behavior

Research date: 6 October 2026. Kogen calls xAI from its own model loop using the user's
SuperGrok OAuth session. It does not launch or wrap the `grok` executable, read Grok's
credential store, or use an xAI API key.

## Login

Grok Build documents browser OIDC as its default sign-in and RFC 8628 device-code login for
SSH and other headless hosts (`grok login --device-auth`). `auth.x.ai` is the OAuth issuer and
is a required network host. The authorization page is served from `accounts.x.ai`. The public
Grok Build source identifies the OAuth client as `b1a00492-073a-47ea-816f-4c329264a828` and
requests `openid profile email offline_access grok-cli:access api:access`, plus conversation
and workspace scopes for the CLI's other features. Kogen requests only the identity and model
access scopes it needs.

Kogen obtains the device authorization and token URLs from the issuer's OIDC discovery
document. Device authorization sends the public client id and scopes; polling uses the standard
device-code grant and honors `authorization_pending`, `slow_down`, and expiry responses. Token
refresh uses the discovered token endpoint with `grant_type=refresh_token`. Refresh tokens can
rotate, so Kogen saves each replacement under a cross-process credential lock before another
request uses it.

On macOS, the tokens are stored AES-256-GCM encrypted in `~/.kogen/credentials/grok-<label>.enc`
with the key in the `kogen` Keychain service. Other platforms use a private Kogen credential
file, matching the existing ChatGPT backend. No Grok CLI auth file is read or copied.

## Inference protocol

Grok Build's enterprise documentation names `cli-chat-proxy.grok.com` as the inference proxy.
The official Grok Build shell README demonstrates OpenAI-compatible Chat Completions at
`/v1/chat/completions` and documents the bearer token, `X-XAI-Token-Auth: xai-grok-cli`, and
`x-grok-model-override` headers. Grok Build also supports the OpenAI Responses backend; its
settings documentation shows `grok-4.7` configured with `api_backend = "responses"`. Kogen uses
that native Responses wire at:

```text
POST https://cli-chat-proxy.grok.com/v1/responses
```

Requests stream SSE and carry `model`, `instructions`, `input`, top-level `tools`,
`reasoning: {effort: ...}`, `store: false`, and `prompt_cache_key`. Kogen sends the required
proxy auth/model-routing headers, a truthful Kogen user agent and client identifier, and
`x-grok-conv-id` with the same stable cache key. Full conversation input is sent on each turn;
Kogen does not depend on a stored `previous_response_id`.

Responses function calls use `function_call` output items and are parsed into Kogen's regular
tool-call contract. Their results return as `function_call_output` input items. For streamed
responses, Kogen consumes the provider's Responses SSE events through the same event contract
used by its ChatGPT provider. The first-byte and total-request caps use Kogen's HTTP transport;
idle stalls and retries use `Kogen.Harness.Exchange`'s shared resilience policy.

## Models, reasoning, cache, and usage

xAI's model docs identify `grok-4.7`, `grok-4.6`, and `grok-4.5`. The reasoning docs say 4.6 and
4.7 accept `low`, `medium`, `high`, and `xhigh` (default `high`); 4.5 accepts `low`, `medium`,
and `high`. These are passed through as `reasoning.effort`. Grok model ids are valid strings in
`build.roles.*.model`; for a Grok account, Kogen's provider defaults use `grok-4.6` at `high`.

xAI automatically caches an unchanged prompt prefix. Its cache guidance recommends a stable
conversation key: Responses accepts `prompt_cache_key`, while Chat Completions uses
`x-grok-conv-id`. Both route a conversation to the same server to improve cache reuse. Kogen's
exchange already creates one deterministic key per Build run and stage; the Grok provider sends
that same key in the request body and affinity header on every turn and retry.

Responses usage reports `input_tokens`, `output_tokens`, and `total_tokens`; cached input is
`input_tokens_details.cached_tokens`, and reasoning output is
`output_tokens_details.reasoning_tokens`. Kogen records input excluding cached input, cached
input, output, and reasoning in its existing request journal and benchmark usage report.

## Network access

For Grok login and inference, allow HTTPS to:

- `auth.x.ai`
- `accounts.x.ai`
- `grok.com`
- `cli-chat-proxy.grok.com`

The public enterprise guide says `api.x.ai` is for the direct API-key path. Kogen does not use
it.

## Sources and limits

- [Grok Build overview](https://docs.x.ai/build/overview)
- [Grok Build enterprise deployments and authentication](https://docs.x.ai/build/enterprise)
- [Grok Build settings and model API backends](https://docs.x.ai/build/settings)
- [Official Grok Build shell README: proxy request and required headers](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/README.md#using-authjson-for-api-access)
- [Official Grok Build OAuth configuration](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-login/src/config.rs)
- [xAI Responses API reference](https://docs.x.ai/developers/rest-api-reference/inference/responses)
- [xAI function calling](https://docs.x.ai/developers/tools/function-calling)
- [xAI streaming](https://docs.x.ai/developers/model-capabilities/text/streaming)
- [xAI reasoning and supported effort values](https://docs.x.ai/developers/model-capabilities/text/reasoning)
- [xAI prompt caching](https://docs.x.ai/developers/advanced-api-usage/prompt-caching)
- [xAI cache affinity guidance](https://docs.x.ai/developers/advanced-api-usage/prompt-caching/maximizing-cache-hits)
- [xAI cached-token usage fields](https://docs.x.ai/developers/advanced-api-usage/prompt-caching/usage-and-pricing)
- [xAI model list](https://docs.x.ai/developers/rest-api-reference/inference/models)

The supplied local research snapshot also reports the device endpoint as
`POST https://auth.x.ai/oauth2/device/code` and the token endpoint as
`POST https://auth.x.ai/oauth2/token`. The Grok Build 1.0.44 executable and its `docs/` directory
were not present at either requested local path on this host, and `grok` was not installed on
`PATH`. I therefore could not verify that exact binary's `--help`, embedded strings, model list,
or version-specific request headers. The documented device flow and official source/docs above
are the basis for this implementation. No auth files were inspected and no provider calls were
made.
