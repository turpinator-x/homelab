# Decision: which gateway goes in front of the model (P1, phase 2)

**Date:** 2026-11-08. **Status:** proposed, not built yet. **AI-assisted:** Claude Code did the research and drafted this. I set the requirements. The choice is waiting for my review in PR #23.

## The problem

The model server from phase 1 has no API keys, no rate limits and no per-request log. It also can't fail over, because there's only one model. Phase 3 needs time to first token measured per request, and llama.cpp's own metrics don't give that.

A gateway sits in front of the model and gives clients one API, so all of that lives in one place instead of in every app.

## What it has to do

| Need | Why |
|---|---|
| OpenAI-style API in front of llama.cpp | Clients shouldn't care what serves the model |
| API keys, one per client | Know who sent what, and cut one client off without touching the others |
| Rate limits by requests and by tokens, without Redis | Tokens are what cost money or CPU. Two nodes don't need a shared limit store yet |
| Failover to a second model | One model is a single point of failure |
| Prometheus metrics, including time to first token | The phase 3 SLO is built on it |
| A log line per request with token counts | Debugging and cost |
| Config in Git, applied by Flux | Same as everything else in this cluster |
| amd64 and arm64 images, runs non-root | This cluster's rules |
| A healthy supply chain | A gateway holds every key. If it's compromised, everything behind it is |

## The options

| | LiteLLM | Envoy AI Gateway | Bifrost | agentgateway |
|---|---|---|---|---|
| Language | Python | Envoy (C++) plus a Go controller | Go | Rust |
| Who runs it | BerriAI (a company) | Envoy project (CNCF) | Maxim (a company) | Agentic AI Foundation, since June 2026 |
| License | Mostly MIT. Enterprise code is under its own license | Apache-2.0 | Apache-2.0 | Apache-2.0 |
| Latest release checked | v1.108.3 (2026-11-07) | v1.2.1 (2026-11-06) | transports v2.5.0 (2026-11-06) | v1.7.0 (2026-10-27) |
| amd64 + arm64 images | Yes | Yes | Yes | Yes |
| API keys | Yes. Needs a Postgres database | Yes, through Envoy Gateway policies | Yes ("virtual keys") | Yes, built in |
| Token rate limits without Redis | Needs its database | No. Token limits need the global rate limit service, backed by Redis | Yes, in memory | Yes, in memory (`localRateLimit` with `type: tokens`) |
| Failover | Yes | Yes | The client has to send a fallback list, or you write routing rules. Circuit breaking is paid-only | Yes. Priority groups, with unhealthy targets taken out for a few seconds |
| Time to first token metric | Yes | Yes | Yes | Yes (`agentgateway_gen_ai_server_time_to_first_token`) |
| What it adds to this cluster | Python app plus Postgres | Envoy Gateway as a second ingress controller next to Traefik, plus Redis | One container | One container |
| Supply chain in 2026 | Compromised twice (below) | Nothing found | Nothing found | Nothing found. Images carry build attestations. I didn't find signing docs |

### LiteLLM's 2026

LiteLLM is the most popular choice and the one most tutorials use, so ruling it out needs a reason:

- **2026-03-24:** versions 1.82.7 and 1.82.8 on PyPI carried a credential stealer. Attackers got the PyPI token through LiteLLM's CI, which ran a compromised copy of the Trivy scanner. LiteLLM rebuilt its release pipeline after this.
- **2026-04:** a critical SQL injection in the proxy's API key check (CVE-2026-42208), fixed in v1.83.10.
- **2026-10-21:** version 1.107.0 was malicious again, on PyPI **and** the official Docker Hub and GHCR images, including the `latest` tags. It was live for about two hours. LiteLLM's own write-up says the attacker started with an admin key committed to a public repo in May, used it to steal maintainers' GitHub tokens, and pointed the release workflow at a look-alike fork. The bad images were signed with the project's real key, so signature checks passed.

Two compromises in seven months, the second one after the pipeline was rebuilt, and the second one reaching the container images. For the component that holds every API key, that's disqualifying for now. It isn't a judgment on the people. The attack in October was patient and well planned, and their incident write-up is honest and detailed.

What it teaches, and what this cluster already does: pin images by digest so a moved `latest` tag changes nothing, and hold updates for a few days (Renovate's release age) so a bad release is usually pulled before it's merged. A digest pin wouldn't have saved anyone who upgraded to 1.107.0 on purpose that morning. The release age would have.

## Decision

**agentgateway, run standalone from a config file.**

- It does everything on the list in one container, with no database and no Redis.
- It's run by a foundation, not one company, and nothing I need is held back for a paid tier.
- It's written in Rust and is small enough to run on the Pi.
- Its metrics follow the OpenTelemetry GenAI naming, so the dashboards and SLO carry over to other tools.

**At a larger company I'd look hard at Envoy AI Gateway.** It's the better fit when Envoy Gateway is already the ingress, with Redis for limits that are shared across many replicas. Here it would mean a second ingress controller and a Redis just for this.

**Rejected:**
- **LiteLLM:** supply chain (above).
- **Bifrost:** a company owns it, and failover and high availability lean on the paid version.
- **Traefik middleware only:** it can check keys and count requests, but it can't see tokens and can't measure time to first token.

## How it'll be built (phase 2)

1. **Pin the image by digest:** `cr.agentgateway.dev/agentgateway:v1.7.0@sha256:60216aafb03d37f94e952ff3d51d2f630a65b10ecaebdc0a864882f92610c45b`. Renovate holds minors and majors for Monday, with a release age.
2. **Keep the keys out of plain text.** The config holds the client API keys, so the whole config file goes in a SOPS-encrypted Secret, like the cluster's other secrets. Nothing secret goes in a ConfigMap.
3. **Lock down the network.** Add a NetworkPolicy so only the gateway can reach the model server. Today any pod in the `llm` namespace can.
4. **Test it on my laptop first** against the same llama.cpp image, before anything goes on the cluster. I'll write down what it shows, including any config option that doesn't match the docs.
5. **Add a second, smaller model for failover.** It runs as a separate deployment. Then stop the first one and check that requests keep working.
6. **Move the model download into its own Job** (from phase 1's notes), so the model server itself has no internet access.
7. **Build the drills before calling it done.** A missing key gets a 401. Going over the limit gets a 429. The first model going down sends traffic to the second. The test checks each result, not just that the command ran.

## What the laptop test showed (2026-11-08)

agentgateway did what its docs say, except one thing. Keys, per-key request and token limits, failover and the metrics all worked. Retries aren't available in the simple config mode, so the request that finds the primary down fails once with 503 before failover starts. The details are in [llm.md](llm.md). It doesn't change the decision. It's written down, and clients retry once.

Step 2 above also changed. The keys can come from environment variables, so only the keys go in a SOPS Secret, and the config stays a readable ConfigMap.

## What would change this

- agentgateway turning out not to work as documented on this cluster (the laptop test comes first for this reason).
- A supply-chain incident in agentgateway.
- A real need for limits shared across several gateway replicas. That means Redis, and Envoy AI Gateway becomes the better fit.

## Sources

- LiteLLM, "Oct 21, 2026 LiteLLM release v1.107.0 compromised": https://docs.litellm.ai/blog/security-incident-oct-21-2026
- LiteLLM, the attack chain behind v1.107.0: https://docs.litellm.ai/blog/security-incident-oct-21-2026-attack-chain
- Datadog Security Labs on both LiteLLM compromises: https://securitylabs.datadoghq.com/articles/litellm-compromised-pypi-docker/
- LiteLLM security blog (CVE-2026-42208): https://docs.litellm.ai/blog
- Envoy AI Gateway, usage-based rate limiting: https://aigateway.envoyproxy.io/docs/capabilities/traffic/usage-based-ratelimiting
- agentgateway v1.0 and the move to its own project: https://agentgateway.dev/blog/2026-03-12-agentgateway-v1.0/
- agentgateway rate limits: https://agentgateway.dev/docs/standalone/latest/documentation/configuration/resiliency/rate-limits.md
- agentgateway API keys: https://agentgateway.dev/docs/standalone/latest/documentation/configuration/security/apikey-authn.md
- agentgateway failover (virtual models): https://agentgateway.dev/docs/standalone/latest/documentation/llm/virtual-models.md
- agentgateway metrics: https://agentgateway.dev/docs/standalone/latest/documentation/observability/metrics/reference.md
- Bifrost OSS and paid features: https://docs.getbifrost.ai/llms.txt
- Release dates and licenses from each project's GitHub releases, checked 2026-11-08. Image platforms checked with `docker manifest inspect`.
