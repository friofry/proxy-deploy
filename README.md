# proxy-deploy

Deploys market-proxy, eth-rpc-proxy and nft-proxy on one plain VPS: Docker Compose
for the services, Caddy in front for TLS and routing by host name.

```
                 :443                  docker network "proxy-edge"
internet ──► Caddy (proxy-caddy) ──┬─► market-front:8080  (market-proxy stack)
                                   ├─► rpc-front:8080     (eth-rpc-proxy stack)
                                   └─► nft-front:8080     (nft-proxy stack)
```

Each stack keeps its own compose file from its repository. Files in `overrides/`
remove the host ports and attach the front nginx to the shared network, so the
repositories stay untouched and update with a plain fetch.

## First deploy

```bash
cp .env.example .env        # fill in domains, basic auth, JWT secret, provider keys
./bootstrap.sh root@HOST    # once per host: Docker, firewall (22/80/443), swap
./deploy.sh root@HOST       # clone, write secrets, build, start, test
```

`deploy.sh` ends with two checks, prints an `ok`/`FAIL` line per check and exits
non-zero if any failed:

- **smoke**: per proxy, `/auth/puzzle` answers; an API request gets 401 without
  credentials, 200 with basic auth and 200 with a bearer token;
- **puzzle**: fetches a puzzle, solves it, exchanges the solution for a token
  and verifies it, using the tester from `proxy-common`.

Puzzle auth only works on a ref that ships it. At the time of writing
`market-proxy@deploy-prod` has basic auth only, so its two puzzle checks fail
until `MARKET_REF` points at a ref with `auth-service` in its compose file.

## DNS and certificates

Caddy can only get a certificate for a name that already points at the host, so
`install.sh` serves a real domain only once it resolves to the host's IP.

1. Before the switch, test through `market.<ip-with-dashes>.sslip.io` (same for
   `rpc.` and `nft.`); these are served when `SSLIP_TEST_DOMAINS=1`.
2. Ask the admins to point the three domains at the host.
3. Run `./deploy.sh -s caddy root@HOST`. The real names are added and their
   certificates issued right away.

If the domains sit behind a CDN or load balancer, set `FORCE_DOMAINS=1`.

A proxy can answer to more than one name: list the others in
`MARKET_EXTRA_DOMAINS`, `RPC_EXTRA_DOMAINS` or `NFT_EXTRA_DOMAINS`
(comma-separated) and run the `caddy` step. Each is served by the same rule: only
while it points at the host. That is also the way out when a name the apps use
ends up pointing here by mistake: add it, and they are served instead of failing
the TLS handshake until the record is put back.

Clients of that other name may ship another basic auth pair. Put it in
`MARKET_EXTRA_BASIC_AUTH_USER` and `MARKET_EXTRA_BASIC_AUTH_PASSWORD` (same for
`RPC_` and `NFT_`) and run the `render` step: the proxy then accepts both pairs.
nginx reads the file on every request, so nothing restarts.

## Day to day

```bash
./redeploy.sh                               # redeploy every droplet of DO_TAG with the refs in .env
./redeploy.sh -r master                     # set MARKET_REF, RPC_REF and NFT_REF to a ref first
./redeploy.sh -n -r master                  # show the refs and hosts, change nothing
./deploy.sh root@HOST                       # redeploy one host (new ref, new key, new template)
./deploy.sh -s smoke root@HOST              # one step: sync|render|check|up|caddy|smoke|puzzle
ssh root@HOST /opt/proxies/kit/remote/install.sh dc rpc ps
ssh root@HOST /opt/proxies/kit/remote/install.sh dc market logs -f --tail 100
```

## Secrets

Everything comes from `.env`; `install.sh render` turns it into the files each
stack mounts:

| Stack | File | Source |
|---|---|---|
| all | `secrets/.htpasswd` | `BASIC_AUTH_USER`, `BASIC_AUTH_PASSWORD` |
| all | `secrets/auth_config.json` | `templates/auth_config.json` + `JWT_SECRET` |
| market | `secrets/coingecko_api_tokens.json` | `COINGECKO_API_KEYS`, `COINGECKO_DEMO_API_KEYS` |
| eth-rpc | `secrets/default_providers.json`, `secrets/reference_providers.json` | `templates/*.json` + `INFURA_API_KEY`, `ALCHEMY_API_KEY` |
| eth-rpc | `secrets/.keydb-url`, `secrets/cache_config.yaml` | `KEYDB_URL` (empty disables the L2 cache) |
| nft | `secrets/alchemy_api_keys.json` | `NFT_ALCHEMY_API_KEY` or `ALCHEMY_API_KEY` |

`.env` is copied to `/opt/proxies/kit/.env` on the host (root only, mode 600).

The provider templates hold the chain list with keys blanked. Regenerate them
when chains change:

```bash
jq '(.chains[].providers[]) |= (.authToken="" | .authLogin="" | .authPassword="")' \
  ../eth-rpc-proxy/secrets/default_providers.json > templates/default_providers.json
jq '(.chains[].provider) |= (.authToken="" | .authLogin="" | .authPassword="")' \
  ../eth-rpc-proxy/secrets/reference_providers.json > templates/reference_providers.json
```

## Creating hosts on DigitalOcean

`provision.sh` wraps `doctl` (install it and run `doctl auth init` first). Set
`DO_SSH_KEYS` in `.env`, then:

```bash
./provision.sh hosts 1                  # creates droplet proxy-1; billed from this moment
./bootstrap.sh $(./provision.sh ips)
./deploy.sh $(./provision.sh ips)
```

Resources are found by the tag `DO_TAG`, so re-running a command creates only
what is missing. `./provision.sh status` shows what exists.

## Behind a load balancer

Auth needs nothing shared except configuration: puzzles and tokens are signed
with `JWT_SECRET`, so any host accepts a token issued by another, and no sticky
sessions are needed.

```
internet ──► load balancer :443 (TLS) ──► host-1 :80 Caddy ──► the three stacks
                                     └──► host-2 :80 Caddy ──► the three stacks
```

1. Set `TLS_MODE=lb` in `.env`. Caddy then serves plain HTTP on port 80, routes
   by host name and answers `/healthz` for the balancer.
2. Create the hosts and deploy with the same `.env`:

   ```bash
   ./provision.sh hosts 2
   ./bootstrap.sh $(./provision.sh ips)
   ./deploy.sh $(./provision.sh ips)
   ```

3. Give the balancer a certificate that covers the three domains and put its ID
   into `DO_CERT_ID`:

   ```bash
   # domains whose DNS is hosted elsewhere: upload a certificate you already have
   doctl compute certificate create --name proxy-cert --type custom \
     --leaf-certificate-path cert.pem --private-key-path key.pem
   # domains whose DNS is managed by DigitalOcean
   doctl compute certificate create --name proxy-cert --type lets_encrypt \
     --dns-names market.example.org,rpc.example.org,nft.example.org
   ```

4. `./provision.sh lb` creates the balancer and a cloud firewall that lets only
   the balancer reach port 80 on the hosts. It prints the address to point the
   domains at.

To test one host directly before the firewall exists:
`curl -H 'Host: market.example.org' http://HOST_IP/auth/puzzle`.

What does not scale for free:

- **CoinGecko quota**: every host runs its own market-fetcher and polls on its own.
- **RPC cache**: without `KEYDB_URL` each host warms its own in-memory cache.
  Point `KEYDB_URL` at one shared KeyDB/Redis to share it.
- **`requests_per_token`** is counted per host.
