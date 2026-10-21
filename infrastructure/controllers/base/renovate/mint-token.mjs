// Exchanges the GitHub App private key for a 1-hour installation token.
import { createSign } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const clientId = process.env.GITHUB_APP_CLIENT_ID;
const installationId = process.env.GITHUB_APP_INSTALLATION_ID;
const key = readFileSync("/app-key/private-key.pem", "utf8");

const b64url = (obj) => Buffer.from(JSON.stringify(obj)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const unsigned = `${b64url({ alg: "RS256", typ: "JWT" })}.${b64url({ iat: now - 60, exp: now + 540, iss: clientId })}`;
const signature = createSign("RSA-SHA256").update(unsigned).sign(key, "base64url");

const res = await fetch(`https://api.github.com/app/installations/${installationId}/access_tokens`, {
  method: "POST",
  headers: {
    Accept: "application/vnd.github+json",
    Authorization: `Bearer ${unsigned}.${signature}`,
    "X-GitHub-Api-Version": "2022-11-28",
  },
});
if (!res.ok) {
  console.error(`GitHub returned ${res.status}: ${await res.text()}`);
  process.exit(1);
}
const { token, expires_at } = await res.json();
writeFileSync("/token/config.json", JSON.stringify({ token }), { mode: 0o600 });
console.log(`Installation token created, expires ${expires_at}`);
