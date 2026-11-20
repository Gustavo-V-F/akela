# CLAUDE.md

Guidance for working in this repository. It condenses the Akela architecture design; when a decision here conflicts with code, this file wins unless the user says otherwise.

## Language rule

Everything in this repository is written in **English**: code, identifiers, comments, docs, commit messages, UI strings in source, test names. Brazilian legal and fiscal terms with no English equivalent stay as proper names (see [Fiscal core](#fiscal-core-brazil)). Portuguese (pt-BR) translations may be added later as separate localized docs; do not add them now.

## Product

**Akela** (pronounced a-keh-LAH, /a.keˈla/, stress on the last syllable; spelled without an accent) is an ERP for any kind of business; its initial market focus is e-commerce and furniture/decor rental shops. The name comes from the wolf that leads the pack in Kipling's *The Jungle Book* (Hindi *akelā*, "alone"). Technical identifiers (crates, packages, binaries, repos, domains) use `akela`. Akela is open source; the repository is public.

Business context:
- Each Location has its own stock and finances, with hierarchical access levels. The e-commerce website can see all Locations or only some.
- Some steps require state validation by the Location's authority; asynchronous replication alone is not enough.
- A Location **never stops** because the internet is down. While offline, that Location's stock shows as unavailable on the website, and only integration with the website and other Locations pauses.
- Workstations run Windows, macOS or Linux. Phones are clients only.

Source design docs (Portuguese, kept outside the repo; reference only):
- Location cluster, local authority and Cloud Node: https://claude.ai/artifact/Cuwgt6cf7FZ1je5Y5ztPmZ
- Cloud server, Consolidated Postgres, Central Registry and CA: https://claude.ai/artifact/QCKLw9EmmstkHnGL73Dgqj

## Glossary

Use exactly these terms, consistently, in code and docs.

| Term | Meaning |
| --- | --- |
| Location | A business unit (e.g. a store or rental shop) with its own stock and finances. Never call it "site" (that word is reserved for the e-commerce **website**). |
| Location Cluster | The rqlite cluster holding one Location's data. |
| Fixed machine | Wired desktop or server at the Location. |
| Eligible laptop | Laptop on the Location's network, plugged in, stable for a few minutes. |
| Mobile device | A phone, or a laptop not meeting the eligibility conditions. |
| Voter | Node that votes in elections and can become Leader. |
| Replica | Non-voting node with a full copy of the data. |
| Leader | The voter that validates the Location's writes. The only authority. |
| Primary vote | A fixed machine, ranked by stability in the Central Registry; in a Location without fixed machines, the most stable eligible laptop. |
| Complementary vote | The Cloud Node and eligible laptops that only complete the majority. |
| Cloud Node | One rqlite node in the cloud per Location, member of that Location Cluster. |
| Central Registry | Cloud registry of customers, Locations, machines, credentials, roles, cluster generation and schema version. |
| CDC Receiver | Cloud service that receives change events from each Location Cluster and writes them to the Consolidated Postgres. |
| Consolidated Postgres | Cloud database with all Locations of a customer; used by the website and reports. Never used to validate. |
| Orchestrator | Cloud service that drives website orders across Locations (saga). |
| Generation | Number that changes every time a Location Cluster is recreated; part of the CDC `service_id`. |
| Customer | The contracting company (tenant). Each customer has its own Locations, CA and data. |
| Buyer | Person or company that buys or rents at a Location. |
| Technical key | Per-row identifier (UUIDv7) used for relations between tables. |
| Readable code | Identifier humans read on screens, contracts and receipts. Never a key. |
| Location Agent | Daemon on each fixed machine and laptop that manages `rqlited`, eligibility and certificates. |
| Membership Manager | Component running alongside each Location's Leader that decides who votes. |

## Architecture overview

- **One rqlite cluster (SQLite replicated via Raft) per Location.** rqlite provides consensus, replication, leader election and CDC. Akela provides voter selection, the path to the cloud, and business rules.
- **One Cloud Node per Location**, member of the Location Cluster. It is the entry point for the website and for phones outside the Location's network (writes are forwarded to the Leader), and the source of the full copy for disaster recovery.
- **Cloud-only Location:** if a Location has no machines of its own, there is no Location Cluster; the Location's database and its only app installation live in the cloud, accessed via web UI or client API. Fiscal documents are issued by that installation.
- **CDC → Consolidated Postgres:** the Leader of each Location Cluster pushes changes over HTTP (at-least-once) to the CDC Receiver.
- **Cloud server** (never validates stock): Central Registry, CDC Receiver, Consolidated Postgres, Orchestrator, schema-migration coordinator, private CA (step-ca), fiscal-authorizer status service.

### Components to build

- **Location Agent** (every fixed machine and laptop): install and keep `rqlited` running as a service on Windows/macOS/Linux; detect eligibility (Location network/cable, AC power, stable latency to other voters); detect imminent departure (shutdown, unplug, network change, suspend) and request demotion first; monitor disk (CDC queue grows during outages); report machine state to the Membership Manager; automatically rejoin a new-generation cluster while keeping old data aside (exception: the old Leader waits for reconciliation); obtain and renew certificates.
- **Membership Manager** (alongside each Leader): pick voters by priority (server → stable desktops → eligible laptops); keep the voter total odd, one change at a time (`.promote` / `.demote` or the API); hysteresis (promote only after minutes of stability, don't demote for short absences); shrink to primary votes after a few seconds without cloud and restore when it returns; auto-remove unreachable nodes with conservative timeouts identical on all voters, disabled for the Cloud Node; leadership watcher.
- **Location app** (workstations and mobile): see invariants below; degraded mode (no majority → validations blocked with a clear message); mobile talks to a local node on the Location network, otherwise to the Cloud Node; "Take over as primary" button protected by manager password, showing each present laptop's applied index.
- **Cloud services** (Rust): Central Registry, CDC Receiver, Orchestrator, migration coordinator, authorizer-status service.

## Voting and authority rules

The authority of each Location is always a machine at that Location. The cloud only lends a vote to complete the majority and is never Leader.

1. **Who votes:** fixed wired machines first. Eligible laptops vote only to reach 2 local voters. Mobile devices never vote.
2. **Odd total:** local voters + Cloud Node always sum to an odd number. Non-voters are replicas with full copies.
3. **1 local voter:** it votes alone; the Cloud Node is a replica.
4. **≥2 local voters:** local voters are kept at an even number and the Cloud Node votes, so surviving machines keep a majority when others die.
5. **Leadership stays local:** if the Cloud Node becomes Leader, the watcher calls stepdown naming a local voter, verifies, and repeats.
6. **Offline, shrink while there is a majority:** after a few seconds without the cloud, complementary votes are demoted one at a time until only primary votes remain, keeping the largest odd number of them by rank (e.g. 2 fixed → 1 voter + 1 replica; 4 → 3 + 1). A voter being demoted transfers leadership first if it is the Leader. Restored when the internet returns.
7. **Laptop leaving:** demoted before disappearing (unplug, network change, suspend). If there's no time, timed auto-removal handles it later (requires a Leader).

| Location type | Voters normally | Voters offline |
| --- | --- | --- |
| 2+ fixed machines | Even number of fixed + Cloud Node | Largest odd number of fixed |
| 1 fixed + laptop | Fixed + laptop + Cloud Node | Fixed only |
| 1 fixed | Fixed only | Fixed only |
| Laptops only | Primary laptop + 1 laptop + Cloud Node | Primary laptop only |
| 1 laptop | That laptop | That laptop |

The primary laptop must be the most stable one (plugged in, suspend disabled, e.g. the front-desk laptop).

### Failure scenarios

| Scenario | Outcome | Action |
| --- | --- | --- |
| Internet down | Complementary votes demoted; Location keeps validating; website shows stock unavailable | Automatic |
| Local voter dies, internet up | Survivors + Cloud Node elect a local Leader (Raft guarantees it has all committed entries) | Automatic |
| Primary voter returns | Rejoins as follower in the same cluster | Automatic |
| Laptop leaves cleanly | Demoted first | Automatic |
| Internet and a complementary vote fail at the same instant | No time to shrink; Location stops until one returns | Wait or manual |
| Sole voter disappears, offline | No majority; Location stops | "Take over as primary" |
| Location destroyed | Indistinguishable from an outage from the cloud | Disaster declared by a person |

### Manual procedures

Both procedures **create a new cluster from a copy and a new generation; never rewrite membership with `peers.json`.** Old nodes therefore cannot rejoin the new cluster without being reinstalled.

**Take over as primary** (sole voter gone, offline): manager picks the laptop with the highest applied index → agent takes a backup (`/db/backup`, node running) → stops rqlite, moves old data aside (never deletes) → starts rqlite as a new single-node cluster → loads the copy with `/boot` → generates a **new generation** (mandatory: a new cluster restarts Raft indexes — confirmed with rqlite v9.4.5 — and the CDC Receiver would drop new events as duplicates) → when online: register the generation in the Central Registry, wipe the Cloud Node and add it to the new cluster → other laptops (replicas) wipe and rejoin without reconciliation → the old primary's data is compared with the new cluster, records only it has are inserted, then it is wiped and rejoins.

Why reconciliation is needed: with a single voter, writes commit on it alone and replicas lag by seconds. A rental confirmed on the old primary just before it suspended exists only there; the new cluster from the replica's copy shows the item as free.

**Location disaster** (destroyed, stolen, hardware lost): a person confirms out-of-band (phone, visit) → declare the disaster in the Central Registry with a new generation and revoke old nodes' credentials → copy the Cloud Node into a new cloud cluster, which becomes that Location's authority → the CDC Receiver accepts the new generation's `service_id` → new machines join that cluster and the watcher moves leadership back to the Location → anything old machines did after the declaration is divergence, reconciled manually.

## Invariants (must not be violated)

1. **The Leader of the Location Cluster is the only authority** for that Location's stock and finances. The cloud, the Consolidated Postgres and the website never validate.
2. **rqlite only through its HTTP API.** Never open the SQLite file directly.
3. **No interactive transactions** (rqlite has none): business rules must be single conditional statements or atomic batches (e.g. "reserve if free" is one conditional statement). Read consistency level is chosen per use case.
4. **Technical keys are UUIDv7** (RFC 9562), generated by the app at write time, before sending to the Leader (`uuid` crate, `Uuid::now_v7()`). Same key flows to Postgres unchanged, stored in `uuid` columns (binary), never as text. Relations use only technical keys. Never use local sequences as IDs. The writing machine is stored in its own column, not in the key. Clock skew affects ordering only, not uniqueness.
5. **Readable codes** (orders, Buyers) are assigned by the Leader, sequential per Location, format `<Location>-<generation>-<type><seq>` (e.g. order `L03-G1-P000123`, Buyer `L03-G1-C000045`). Unique per (Location, generation, type, sequence). Never a key, never used in relations. A machine without majority cannot write, hence cannot issue codes.
   - Normal generation: issued by the Central Registry (e.g. `G1`).
   - Generation from "Take over as primary": previous generation + the taking machine's code (e.g. `G1M07`); machine codes are assigned at enrollment and unique per Location. After reconciliation the Central Registry records the generation now in force.
6. **CDC dedupe** by key (`service_id` including generation, Raft index); ignore indexes ≤ the last processed for that key. Respond **2xx only after the Postgres commit**. Each INSERT/UPDATE/DELETE event (with before/after values) becomes SQL on Postgres.
7. **Schema migrations** (CDC does not carry schema changes) are applied via the rqlite API to every Location Cluster and to the Consolidated Postgres, with the version tracked in the Central Registry. Offline Locations get the migration on reconnect, before resuming events.
8. **Website orders are a saga** driven by the Orchestrator: order created `PENDING` → expiring conditional reservation at each Location via its Cloud Node → if any refuses/unreachable, compensate (release) and offer to proceed with what's available or cancel → payment: authorize → confirm reservations at all Locations → capture (if a confirmation fails, void the authorization; no refund needed) → after all confirmations (point of no return), retry capture until it succeeds. Every call carries the order ID (idempotent, no double reservation). Reservation TTL > confirmation window. Each Location records its share of the order; the cloud records the payment.
9. **Fiscal documents are issued and transmitted only by the Location app** (same code in every installation; deployment/config differs). Central Registry, CDC Receiver and Consolidated Postgres never issue them; Postgres receives already-issued documents via CDC.
10. **Fiscal conformance = the authorizer's response** in homologation (test) and production environments. Third-party library tests are only input cases; expected results always come from the authorizer.
11. **mTLS everywhere** for rqlite (node↔node Raft and client↔node API), inside Locations and with the cloud, using certificates from the Location's trust scheme (see [Location trust schemes](#location-trust-schemes)); in scheme 1, blocking a machine removes its fingerprint from the bundle. `-node-verify-client` and `-http-verify-client` on for all nodes; plus rqlite `-auth` with least-privilege users.
12. **Certificates have no CRL/OCSP endpoints** (so no verifier, including Windows', tries to reach them offline). Revocation is **passive**: step-ca refuses renewal. Validity exceeds the longest accepted outage with margin (e.g. 90 days for up to 30 days offline). Renewal at ~2/3 of validity (`step ca renew --daemon`, `--exec` restarts `rqlited`). Offline validation is local (chain to installed root, dates vs. local clock).
13. **Root CA key is offline**, used only to sign intermediates, never automatically, with a multi-person procedure. Intermediate key online in step-ca with strong password, preferably in KMS/HSM. JWK provisioner private key lives in OpenBao and is read only by the Central Registry.
14. **Let's Encrypt only on public endpoints** (website, public cloud API, Keycloak) behind Caddy. **The Cloud Node is not behind Caddy**: it is exposed on its own port with rqlite mTLS, because a TLS-terminating proxy would prevent client-cert verification.
15. **The cloud never opens connections toward a Location**; Locations open outbound connections (e.g. the authorizer-status SSE stream).

## Central Registry

Single source of configuration; agents read from it who they are, whom they talk to and which generation they're in.

- Records: customers, Locations, machines, roles (primary voter, complementary voter, replica), credentials.
- Versioned membership per Location Cluster; changed only with the cloud reachable, one machine at a time.
- Generation per Location Cluster; schema version per Location Cluster.
- Heartbeat per Location: when it stops, the website shows that Location's stock as unavailable.
- Machine enrollment: after admin approval, generates a one-time token (JWT signed with the JWK provisioner key from OpenBao: `kid`, `iss` = provisioner name, `aud` = `https://<ca>/1.0/sign`, `nbf`/`exp`, random `jti`, `sans`, optional `sha` = root fingerprint) that the agent exchanges at step-ca `POST /sign` for server+client certs; the private key is generated on the machine. Also assigns what the country's fiscal rule needs for takeover numbering (Brazil: a reserved series unique among the issuer's machines).
- Machine block: revoke at step-ca (`POST /revoke` with `serial`, `ott`, `reasonCode`, `passive: true`) and signal the Membership Manager to remove it.
- Disaster declaration: new generation + revoke old nodes' credentials.
- Per customer: CA address, root fingerprint, mode (self-hosted or SaaS).
- CA bundle may contain more than one root (root rollover).

## Buyers

- Document (CPF, CNPJ or foreign document) is optional at registration; stored as type + normalized number. When present, unique within the Location (enforced by the Leader, even offline). Email optional, not unique. Document, email, name and phone are searchable; the readable code identifies the Buyer in UI and paperwork.
- People (individuals or companies) have a single record with one or more roles: buyer, carrier, intermediary. Registering from the registry section or inline in a form writes the same record.
- **Cross-Location merge** happens in the Consolidated Postgres (two offline Locations may register the same Buyer): same document → merge; same email with different/missing documents → suggest, a person confirms. The surviving technical key receives references; the other becomes an alias. The oldest readable code becomes primary; the other stays valid as secondary (old documents, search).

## Fiscal core (Brazil)

Fiscal issuance is the core of the system: every operation ends in a fiscal document when the law requires, and stock, finance and orders work around it.

General rules:
- **Scope:** each country's fiscal core covers every taxation model, tax regime, document and operation type its law defines, for any kind of business. Never limit fiscal rules by Akela's initial market (e-commerce, rental). Only rules no longer in force at launch (2027) are left out.
- Fiscal rules are separated **per country**: each defines its documents, the data each operation requires from each party, numbering and transmission. Each country implements only what its law requires (e.g. the US: sales tax per jurisdiction and exemption certificates, no e-invoicing).
- Fiscal/financial pending items: each operation declares required data; the system shows what's missing and why. Checked at the Location, works offline.
- Issuer configured per Location (Brazil: CNPJ + state registration). In the cloud, all of a customer's issuers are consolidated in that customer's tenant for administration.
- Homologation is done at every authorizer where a customer issues (validations vary by UF). Each homologation case stores the sent XML and the authorizer response (status code and reason) as a reference case; on each new Technical Note (NT) or schema package, reference cases are resent and responses compared. Legal rules the authorizer doesn't check (contingency deadlines, document obligation by date/tax regime) get their own tests derived from the legal text.
- Initially the fiscal core uses forks of compatibly-licensed third-party libraries, replaced gradually by in-house code; each replaced part goes live only after meeting the conformance criterion in homologation and production.

Brazilian terms (kept as proper names): **NF-e** (electronic invoice, model 55), **NFC-e** (consumer invoice, model 65), **NFS-e** (service invoice, national standard; submitted as a **DPS**), **CT-e** (transport document, model 57), **MDF-e** (cargo manifest, model 58), **SEFAZ** (state tax authority), **SVRS/SVAN/SVSP** (shared virtual authorizers), **SVC-AN/SVC-RS/SVC-SP** (contingency authorizers), **ADN** (NFS-e national data environment), **CNPJ/CPF** (company/individual tax IDs), **CFOP** (fiscal operation code), **UF** (Brazilian state), **ICMS** (state VAT), **RICMS** (state ICMS regulation), **Simples Nacional** (simplified tax regime), **MEI** (individual micro-entrepreneur), **ISS** (municipal service tax), **IPI** (federal excise on manufactured goods), **PIS/Cofins** (federal contributions replaced by CBS), **CBS** (federal VAT), **IBS** (state/municipal VAT), **IS** (Imposto Seletivo, excise on harmful goods), **ZFM** (Manaus Free Trade Zone).

Brazil tax reform (LC 214/2025):
- From 2027 documents carry CBS (full rate) and IBS (test rate in 2027–2028, rising 2029–2032, full in 2033).
- ICMS, ISS and IPI coexist with IBS/CBS through 2032. ICMS and ISS are extinct in 2033. IPI is zeroed from 2027 except for products competing with the ZFM, but is not extinct.
- In scope: IS; every apportionment regime (regular, Simples Nacional including the option to pay CBS/IBS outside it, MEI); specific regimes (fuels, financial services, real estate, health, cooperatives, etc.); differentiated regimes (30%/60% reductions, zero rate, ZFM and free-trade areas); split payment (after launch, still in scope).
- All rates, shares and transition rules are effective-dated data, never hard-coded.
- Out of scope: the 2026 test phase (CBS 0.9% / IBS 0.1% offset against PIS/Cofins) and PIS/Cofins calculation on issuance. PIS/Cofins fields are still parsed on received documents and on documents referenced by returns.
- Confirm details against the law and the Receita Federal reference calculators (`ReceitaFederal/calculadora-rtc-*`, MIT) before specifying.

Numbering and issuance:
1. Numbering is per issuer (CNPJ), model and series; each series has its own sequence. Each Location has its own issuer, and only the Leader numbers, so numbers never collide, even offline. The Leader numbers in the Location's normal series.
2. **Reserved series per machine**, assigned at enrollment, used only while that machine operates as primary after "Take over as primary"; the majority side keeps using the normal series. Must respect legal ranges per model/UF (NF-e: 1–889 normal; 890–899 and 900–999 reserved by SEFAZ). After reconciliation the cluster returns to the normal series from its last number; the reserved series continues its own sequence next time.
3. **Offline contingency:** documents issued in contingency are queued at the Location and transmitted when the internet returns, with automatic retries. The UI warns when a document approaches the issuer state's transmission deadline.
4. **Authorizer status signal:** the Location app keeps an outbound SSE connection (mTLS) to the cloud's authorizer-status service, which consumes monitor-sefaz's `/stream` and sends each Location only events for its UFs (last state first, then changes). It's auxiliary: before switching issuance mode, the Location confirms via the authorizer's own service-status query. Without SSE, the Location decides from the authorizer's response alone.
5. **NFS-e:** no availability monitoring (the national standard has no status query; the cloud tracks scheduled outages from the NFS-e portal news). A failed DPS stays queued; **before each retry, query by DPS ID whether the NFS-e was already generated.** Gaps in NFS-e numbering are normal, not errors.

Issuance requirements for Buyers:
- Remote sale with NF-e: recipient name + CPF/CNPJ.
- NFC-e with home delivery: full recipient address (since 2026-08-03, Ajuste SINIEF 9/2026).
- NFC-e above the state's identification threshold: Buyer identification. Below it, in-person sale: identification optional, invoice still mandatory.
- Rental of movable goods: NFS-e mandatory on every charge from 2026-12-01 (Simples Nacional: 2027-01-01), per Ato Conjunto RFB/CGIBS 4/2026.

Typical uses, not exhaustive: every document is implemented for every operation type the law allows.

| Document | Typical use | Issuer | Authorizer |
| --- | --- | --- | --- |
| NF-e (55) | B2B and interstate sales, returns, inbound; shipment of goods for rental without ICMS (SP: CFOP 5.908/6.908) and return of rented goods | The Location. Return in SP: ICMS-taxpayer lessee issues outbound NF-e (CFOP 5.909/6.909); non-taxpayer → Location issues inbound NF-e (CFOP 1.909/2.909) referencing the shipment NF-e. Other UFs: per their RICMS | Own SEFAZ (AM, BA, GO, MG, MS, MT, PE, PR, RS, SP), SVRS (other UFs except MA), SVAN (MA). Contingency: SVC-AN or SVC-RS per UF |
| NFC-e (65) | In-person sale to end consumer | The Location | Own SEFAZ (AM, GO, MG, MS, MT, PR, SP) or SVRS. Offline contingency on the machine |
| NFS-e (national) | Rental of movable goods; services (assembly, installation); intra-municipal freight for third parties | The Location | Sefin Nacional (national issuer, registered in ADN) or the municipality's own issuer (shares with ADN) |
| MDF-e (58) | Goods transport in own/leased vehicle or with independent carrier, when the UF requires | Whoever transports (the Location for own delivery) | SVRS for all UFs |
| CT-e (57) | Only when the Location provides inter-municipal/interstate transport to third parties | The transporting Location | Own SEFAZ (MG, MS, MT, PR, SP), SVSP (AP, PE, RR) or SVRS (others). Contingency: SVC-SP or SVC-RS |

- Delivery with own or rented vehicle is not a transport service: no CT-e; cargo travels with NF-e and, when required, MDF-e. Hired carrier: carrier issues CT-e and MDF-e; Location issues only NF-e.
- Events: cancellation, correction letter, number voiding (NF-e, NFC-e); cancellation and closure (MDF-e); recipient acknowledgement on purchase NF-e.
- ICMS rules, part of NF-e/NFC-e validations and MDF-e obligation are per UF; Akela applies the issuer's UF rules.

## Stack

All in-house code is **Rust**. Rule: when there is no official or mature Rust client, integrate directly via the component's HTTP API with a plain HTTP client + Rustls.

| Concern | Choice |
| --- | --- |
| HTTP server, mTLS | Axum + Rustls (client-cert verification configured in Rustls) |
| rqlite | Direct HTTP API, mTLS; on connection error/timeout try the next known node |
| PostgreSQL | sqlx (pool, transactions, migrations) |
| NATS JetStream | async-nats (cloud-internal messaging, outbox pattern; Location↔cloud stays rqlite CDC) |
| SeaweedFS (S3) | aws-sdk-s3 with SeaweedFS endpoint and `force_path_style` |
| step-ca | Enrollment token generated locally (no HTTP); `POST /revoke`, `GET /health` via HTTP; machines renew with `step ca renew --daemon` |
| OpenBao | Direct HTTP under `/v1`, `X-Vault-Token` or `Authorization: Bearer`; KV v2 at `/v1/<mount>/data/<path>` |
| Keycloak (cloud access only; Location login is local) | Validate JWTs against the realm's JWKS (cached, refreshed periodically) |
| Metrics | metrics-exporter-prometheus, scraped by vmagent |
| UI | Dioxus (web, desktop and mobile), including the website/storefront |
| CLI | clap |
| IDs | `uuid` crate (`Uuid::now_v7()`) |

Off-the-shelf components (used as-is): rqlite, PostgreSQL (+ full-text search + pgvector, no separate search engine), NATS JetStream, SeaweedFS (images, backups), Keycloak (federates the customer's LDAP or the base OpenLDAP, read-only bind, ppolicy overlay), OpenLDAP, VictoriaMetrics + vmagent (cluster version for per-tenant isolation in SaaS), VictoriaLogs, vmalert + Alertmanager, Grafana (unmodified, AGPL-3.0), Caddy (public HTTP endpoints only), OpenBao, step-ca, monitor-sefaz (MIT, Node.js ≥22.12, separate service, included by default, removable via config; covers NF-e, NFC-e, CT-e, MDF-e).

### User interfaces

- **Location app (installed):** Dioxus in desktop mode (system WebView: WebView2 on Windows, WKWebView on macOS, WebKitGTK on Linux) and web mode served by the same installation, simultaneously. The Windows installer bundles the offline WebView2 Runtime installer and runs it when missing, so offline machines can open the app.
- **Location app (cloud):** web mode only (cloud has only SSH/HTTP access), available only for Locations with a Cloud Node.
- **Cloud server:** Dioxus web (WASM) served as static files behind Caddy, calling the same HTTP API as the CLI, login via Keycloak; plus a clap CLI. Web UI and CLI expose the same operations; no feature exists only in one of them.
- Location app also has a clap CLI for debugging and version display.

## Deployment modes

Self-hosted and SaaS use the **same code and design**. Locations (machines, agent, local rqlite) are identical in both.

| Component | Self-hosted | SaaS |
| --- | --- | --- |
| Locations | Customer | Customer |
| Cloud Nodes, Central Registry, step-ca, CDC Receiver, Consolidated Postgres, Orchestrator, backups/monitoring/updates | Customer | Akela operator |
| Root CA key | Customer | Upper tier: customer (can leave SaaS taking the PKI); lower tier: operator |

SaaS adds: per-customer isolation (own Postgres/database, Cloud Nodes, CA, credentials); step-ca per customer; the cloud accepts a window of older agent versions (offline Locations may lag for days); migration between modes via membership change of Cloud Nodes, Postgres copy/rebuild, and Central Registry repointing agents.

### Location trust schemes

Each customer chooses how its Locations get certificates and membership. Traffic is always TLS with client verification; only the trust anchor changes.

| Scheme | Trust anchor | Membership, generation, reserved series | Cloud Node, CDC, website |
| --- | --- | --- | --- |
| 1. Local, no CA node | Each machine's self-signed certificate; a manager approves the machine and its fingerprint is pinned in a bundle every node trusts | Registry tables in the Location Cluster | None |
| 2. Local with CA node | step-ca on a fixed machine of the Location | Registry tables in the Location Cluster | None |
| 3. Local with CA node in the cloud | The customer's cloud step-ca | Central Registry | Yes |

- Without a Cloud Node (schemes 1 and 2) the Location always uses the offline voting rules: the largest odd number of primary votes.
- Moving 1 → 2 or 2 → 3 re-enrolls machines one at a time under the new anchor; nodes trust both anchors during the transition, as in a root rollover. In 2 → 3 the local registry tables are copied into the Central Registry, which becomes the source.

## Operations

- Backups: Cloud Nodes → S3-compatible storage (covers each Location's data); Consolidated Postgres has its own backups (also rebuildable from Cloud Nodes); Central Registry DB and intermediate key (KMS). Restores tested periodically.
- Alerts: disk, node down, leadership outside the Location (Cloud Node Leader too long), Location without majority, Location without heartbeat, CDC Receiver lagging behind Location indexes, certificates/intermediate near expiry.
- Periodic failure drills: cut internet, power off server, power off complementary voter. rqlite upgrades without taking the Location down.
- Intermediate rotation: automation prepares the request, a person signs with the offline root, automation installs. Root rotation: human procedure; the agent distributes a CA bundle with both roots during transition. Renewal after expiry is an optional, security-weakening provisioner setting, only for machines of long-offline Locations.

## Known limits (accepted)

- Simultaneous loss of internet and a complementary vote stops the Location until one returns.
- Offline, the Location cannot survive loss of its primary voter without manual action.
- Seconds-long async window: data committed locally but not yet in the cloud can be lost in a disaster.
- The CDC queue grows on disk during long outages (needs alerting).
- No interactive transactions in rqlite: business rules must fit conditional statements.
- Website data in the Consolidated Postgres may lag by seconds.

## Rejected alternatives (don't re-propose without new information)

SymmetricDS (async multi-master, no authority/failover), PowerSync / ElectricSQL (Postgres is the authority, none at the Location), dqlite (Linux-only, no CDC), LiteFS (needs Consul, FUSE), Marmot (leaderless, eventual consistency), fixed authority with manual failover (Location stops until someone acts), leader lottery without quorum (split brain), two witnesses one per side (even total, ties on outage).

## Roadmap

The Location is the primary focus; the cloud is its evolution.

- Steps run in numeric order.
- ⚠ marks an architecture gate: if it fails, revisit the design before moving on.
- Backend comes before frontend. No business rule lives in a frontend. Every operation exists in the API before it exists on a screen.

### 1. Preparation

**1.1 Spec review.** Fix errors and gaps in the architecture before writing code. Feasibility tests in section 2 use a lab CA; the trust schemes come in 3.1 and 4.2.

Done when every invariant is a testable criterion and every gap has a decision or an owner.

**1.2 CI machine.** A Linux host running OneDev and Podman, with Caddy and HTTPS in front of OneDev. The firewall allows only 22/80/443, and SSH is key-only. The provisioning script lives in `infra/ci/` and is provider-agnostic: host, domain and keys are parameters, so it runs on any cloud. Tests can run locally until it is ready.
- **Podman:** OneDev officially supports only Docker, so Podman's Docker-compatible API socket is mounted where OneDev expects `/var/run/docker.sock`.
- **OneDev is the primary repository** and the single place where tests are planned and their results are seen. GitHub is a read-only public mirror: never push to it directly. Pull requests and issues happen on OneDev; the mirror's README points contributors there.
- **Mirror:** a OneDev job with the "Push to Remote" step pushes each updated branch and tag to GitHub, authenticated by a GitHub token stored as a OneDev job secret, without force-push.
- **Where each test runs**, chosen by the runner it needs:

  | Target | Runs on |
  | --- | --- |
  | Web; Linux desktop; rqlite cluster and failure tests (containers) | OneDev, Docker executor over Podman |
  | Windows; macOS; Android; iOS | GitHub Actions, standard GitHub-hosted runners (free while the repository is public) |

- **Results back in OneDev:** the GitHub workflows trigger on push to the mirror. After the push, a OneDev job waits for the GitHub run of the same commit (`gh run list --commit <sha>`, then `gh run watch <run-id> --exit-status`) and fails if that run fails, so OneDev shows every platform's result.
- **GitHub Actions details:** Apple signing and notarization secrets live in GitHub Secrets. Android emulator tests run on `ubuntu-latest` with KVM hardware acceleration, enabled by a udev-rule step before the emulator starts. iOS simulator tests run on macOS runners (simulator runtimes per image are listed in `actions/runner-images`).

Done when the script builds the machine from scratch, a 3-node rqlite test (kill one node, a new Leader is elected) runs on OneDev, a push to OneDev is mirrored to GitHub, and a hello-world build on each GitHub Actions platform reports its result back in OneDev.

**1.3 Fiscal paperwork.**
- Get the test issuer's digital certificate.
- Get homologation access for:
  - NF-e and NFC-e, at the issuer state's SEFAZ, including the NFC-e CSC token;
  - NFS-e, at Sefin Nacional/ADN, or the municipality's own issuer if it has one;
  - MDF-e, at SVRS;
  - CT-e, at the issuer state's authorizer.
- Enable the document distribution service, for recipient acknowledgement.

Done when each document and the acknowledgement can send a test request and get a response.

### 2. Location feasibility

**2.1 ⚠ rqlite capabilities.** Verify in practice that rqlite can:
- change a node between voter and non-voter at runtime;
- transfer leadership to a chosen node;
- auto-remove unreachable nodes, excluding one node;
- back up and restore (`/db/backup`, `/boot`);
- emit CDC, including with a new `service_id`;
- have a follower forward writes to the Leader;
- read with a chosen consistency level per call;
- trust a bundle of pinned self-signed certificates and reload a changed CA file without restart (automatic reload of node certificates and keys exists since 8.37.0).

Done when a "capability → exists / how / limits" table exists, backed by one automated test per item.

**2.2 ⚠ Fiscal feasibility.** In homologation, from Rust:
- issue 1 NF-e;
- issue 1 NFC-e, including in offline contingency;
- issue 1 NFS-e;
- issue 1 MDF-e and close it;
- issue 1 CT-e;
- query received NF-e and register a recipient acknowledgement.

Done when all are authorized or registered, with an estimate of the in-house work remaining.

**2.3 Domain spec.** Products, stock, rentable units, rental contracts, sales, finance and hierarchical access. Each operation gets its rules, its required data and the fiscal document it produces.

**2.4 ⚠ Membership Manager + failure tests.** Build a prototype in containers, with a simulated Cloud Node. Test every scenario from the failure table, plus network partitions, latency and packet loss. Done when there are never two Leaders, no committed data is lost, and both of these are measured: the demotion window, and the extra write latency caused by the cloud vote.

**2.5 ⚠ Business rules without transactions.** Each of these must be a single conditional statement:
- reserve-if-free;
- rental availability per period;
- next readable code;
- next fiscal number;
- unique CPF/CNPJ per Location.

Done when concurrent-write tests show no double reservation or duplicate number.

**2.6 ⚠ Installation and agent on real machines.** On Windows, macOS and Linux, automated in CI (Linux on OneDev; Windows and macOS on GitHub Actions). AC power, suspend and network-change detection sit behind an interface tested with simulated events; physical laptops only run a final smoke test, since no CI runner has a battery.
- offline installer:
  - Windows: offline WebView2;
  - macOS: Apple signing and notarization;
  - Linux: WebKitGTK;
- `rqlited` and the agent as services;
- detection of AC power and of the Location network;
- early warning of suspend or departure, in time to demote;
- clock behavior.

Done when installation works offline and the laptop is always demoted before it disappears.

**2.7 Manual procedures.** Take over as primary, Location disaster, and reconciliation. Done when the "chair #7" example (a rental confirmed only on the suspended laptop) is reproduced and reconciled without loss.

### 3. Location product

**3.1 Local trust schemes.** Schemes 1 (pinned self-signed certificates) and 2 (step-ca on a fixed machine), with the registry tables in the Location Cluster, manager approval, blocking, and the 1 → 2 move. Done when a Location under each scheme enrolls, blocks and re-enrolls machines with no internet at all.

**3.2 Identity and permissions at the Location.** Akela is local-first: users, password hashes and hierarchical permissions live in the Location Cluster, and the Location app validates login locally, online or offline. A user may exist only at the Location. Keycloak is optional and only for cloud access; how a local user links to a cloud identity is decided here.

**3.3 Complete fiscal core.**
- **Documents:** NF-e, NFC-e, NFS-e, MDF-e, CT-e first; then any other document the law defines, per the fiscal-core scope.
- **Taxes and regimes:** ICMS, ISS, IPI, CBS, IBS, IS with effective-dated rates; regular, Simples Nacional and MEI; specific and differentiated regimes.
- **NF-e/NFC-e events:** cancellation, correction letter, number voiding.
- **MDF-e events:** cancellation and closure.
- **Purchase NF-e:** query of received documents and recipient acknowledgement (awareness, confirmation, unknown operation, operation not performed).
- **Numbering:** the Location's normal series plus a reserved series per machine.
- **Contingency:** offline queue with automatic retries and deadline alerts.
- **NFS-e retries:** check by DPS ID before each retry.
- **Regression:** reference cases resent in homologation on each new Technical Note or schema package.
- **No cloud monitor yet:** the Location decides from the authorizer's own response.

**3.4 Location app backend.** Stock, rentals, finance and orders on top of the fiscal core, all exposed through an API. Done when every domain operation works through the API alone.

**3.5 Location operations.** Local backup and restore, rqlite and agent upgrades without downtime, and local alerts (disk, node down, no majority).

**3.6 Location app UI.** Dioxus desktop and web, consuming the 3.4 API.

**3.7 Mobile app on the Location network.** Dioxus mobile. The phone talks to a local node.

### 4. Cloud feasibility

**4.1 CDC → Consolidated Postgres + minimal Central Registry + schema migrations.** Done when a Location that was offline for days, or whose cluster was recreated, syncs without duplicates or losses, and receives the pending migration before resuming events.

**4.2 PKI (step-ca), scheme 3.** Real enrollment with approval, automatic renewal, passive revocation and offline validation on Windows, plus the 2 → 3 move. Done when a machine is enrolled, renews, is blocked and leaves the cluster automatically, and a scheme-2 Location moves to scheme 3 without stopping.

**4.3 Order saga.** Expiring reservations across Locations, compensation and idempotency, with simulated payment (the payment provider is chosen later). Done when no failure combination yields a double reservation, a charge without stock, or a stuck reservation.

### 5. Cloud product

**5.1 Central Registry + CLI.** Customers, Locations, machines, roles and credentials, operated from the command line.

**5.2 Real Cloud Node.** Joins each Location Cluster and votes when the rules say it should.

**5.3 Fiscal authorizer monitor.** SSE feed to each Location, used as an auxiliary signal.

**5.4 Buyer merge.** Combines duplicate Buyer records across Locations.

**5.5 Cloud operations.** Backups, metrics, logs and alerts.

**5.6 Offering modes.** Self-hosted, multi-tenant SaaS, and cloud-only Locations; Locations under schemes 1 and 2 need no cloud.

**5.7 Cloud web UI.** Administration, using the same API as the CLI.

**5.8 Location app via the cloud.** Browser and phone access from outside the Location network, through the Cloud Node.

**5.9 Website/storefront.** Reads the Consolidated Postgres and creates orders through the 4.3 saga.
