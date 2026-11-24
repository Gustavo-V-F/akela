# Roadmap

The Location is the primary focus; the cloud is its evolution.

- Steps run in numeric order.
- ⚠ marks an architecture gate: if it fails, revisit the design before moving on.
- Backend comes before frontend. No business rule lives in a frontend. Every operation exists in the API before it exists on a screen.

## 1. Preparation

**1.1 Spec review.** Fix errors and gaps in the architecture before writing code. Feasibility tests in section 2 use a lab CA (except the rqlite capabilities test in 2.1 that checks scheme 1's approved list of self-signed certificates) and a lab manager password; local login comes in 3.1 and the trust schemes in 3.2 and 4.2.

Done when every core rule is a testable criterion and every gap has a decision or an owner.

**1.2 CI tests.** The CI server already exists: an AlmaLinux 9 host running OneDev (`onedev.eusou.dev.br`) with Podman, and Caddy with HTTPS in front of OneDev. Its network and access details are secrets and stay out of the repository. This step creates no machine; it only creates the CI jobs and tests. Tests can run locally until they are in place.
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

Done when a 3-node rqlite test (kill one node, a new Leader is elected) runs on OneDev, a push to OneDev is mirrored to GitHub, and a hello-world build on each GitHub Actions platform reports its result back in OneDev.

**1.3 Fiscal paperwork.**
- Get the test issuer's digital certificate.
- Get homologation access for:
  - NF-e and NFC-e, at the issuer state's SEFAZ, including the NFC-e CSC token. Where that SEFAZ accepts NFC-e only from a credentialed issuing software, even in homologation (Santa Catarina: RICMS/SC Anexo 11, art. 94), NFC-e is tested instead in another UF's homologation environment: first at SEFAZ-RS, which registers a company without an RS state registration for homologation only, on request to GS1 Brasil's national fiscal-documents group (`nfe@gs1br.org`); else in SEFAZ-AM's open developer environment, which needs no credential or state registration in Amazonas and uses a fixed CSC. If neither authorizes documents signed with the test issuer's certificate, NFC-e follows the rule in 2.2;
  - NFS-e, in the national restricted environment (Produção Restrita, Sefin Nacional/ADN);
  - MDF-e, at SVRS;
  - CT-e, at the issuer state's authorizer.

This covers one test issuer in one UF plus the national NFS-e restricted environment (Produção Restrita). Other authorizers are homologated, when needed, as part of 3.3, with an issuer each authorizer accepts: an issuer of that UF for a UF's own SEFAZ, or an issuer of any served UF for SVRS and SVAN. In a UF where Akela's company has no establishment, its own CNPJ becomes that issuer when the UF's SEFAZ registers it in the homologation CCC as a test taxpayer (`indContribTeste`, Boletim Técnico 2015.001 - CCC; NT 2026.007 v1.10 stopped the Receita Federal registry checks from rejecting it). SP and RS take this request through GS1 Brasil (`nfe@gs1br.org`); other UFs by request to their SEFAZ.

Done when each document and the acknowledgement can send a test request and get a response.

## 2. Location feasibility

**2.1 ⚠ rqlite capabilities.** Verify in practice that rqlite can:
- change a node between voter and non-voter at runtime;
- transfer leadership to a chosen node;
- report unreachable nodes and remove a chosen one through the API, sparing one node, and let a removed node rejoin as a non-voter;
- back up and restore (`/db/backup`, `/boot`);
- emit CDC, including with a new `service_id`;
- have a follower forward writes to the Leader;
- read with a chosen consistency level per call;
- trust a list of approved self-signed certificates, applying each approval and block by restarting `rqlited` one node at a time (Leader last, after transferring leadership), including with a single voter and with a machine that was off during the change (rqlite reads the CA file only at startup).

Done when a "capability → exists / how / limits" table exists, backed by one automated test per item.

**2.2 ⚠ Fiscal feasibility.**

First, certificate custody (ADR-0005). On Windows, macOS and Linux, an issuer certificate kept in each local store must do both of its jobs from Rust: sign documents and authenticate the TLS connection to the authorizer. Its private key must never leave the store. The stores are:
- the operating system's store;
- the agent's own store;
- a PKCS#11 token;
- on Windows, a smart card seen through the certificate store.

Then, in homologation, from Rust:
- issue 1 NF-e;
- issue 1 NFC-e, including in offline contingency;
- issue 1 NFS-e;
- issue 1 MDF-e and close it;
- issue 1 CT-e;
- query received NF-e and register a recipient acknowledgement.

A document is left out of this step only when no homologation environment accepts it without a credential of the issuing software or its developer that Akela does not hold yet; it then moves to 3.3.

Done when the certificate does both jobs from every store on every operating system, and every document and event above is authorized or registered, with an estimate of the in-house work remaining.

**2.3 Domain spec.** Products, stock, rentable units, rental contracts, sales, finance and hierarchical access. Each operation gets its rules, its required data and the fiscal document it produces. Also defines the readable-code details left open by RFC-0001 (Location core architecture): the Location code, the type letters, the sequence width, what happens when a sequence overflows, and the normal generation format without a Central Registry.

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

## 3. Location product

**3.1 Identity and permissions at the Location.** Akela is local-first: users, password hashes and hierarchical permissions live in the Location Cluster, and the Location app validates login locally, online or offline. A user may exist only at the Location. Keycloak is optional and only for cloud access; how a local user links to a cloud identity is decided here.

**3.2 Local trust schemes.** Schemes 1 (approved list of self-signed certificates) and 2 (step-ca on a fixed machine), with the registry tables in the Location Cluster, manager approval, blocking, and the move from scheme 1 to 2 (from the approved list to a step-ca on a Location machine). Done when a Location under each scheme enrolls, blocks and re-enrolls machines with no internet at all.

**3.3 Complete fiscal core.**
- **Documents:** NF-e, NFC-e, NFS-e, MDF-e, CT-e first, for every UF authorizer and NFS-e through the national model (see Coverage in [AGENTS.md](AGENTS.md#fiscal-core-brazil)); then every other document the law defines, per the fiscal-core scope. The second group, from the Receita Federal schedule of IBS/CBS documents (Ato Conjunto RFB/CGIBS 4/2026, amended by 7/2026):
  - CT-e OS (model 67): transport of people by travel agencies or carriers, of valuables and of excess baggage;
  - BP-e (model 63): passenger tickets, including semi-urban, metropolitan and air transport;
  - GTV-e: transport of valuables;
  - DC-e: declaration of contents for goods moved without another fiscal document;
  - NF3e: electric energy;
  - NFCom: communication services;
  - NFAg (model 75): water and sanitation;
  - NFGas (model 76): piped gas;
  - NF-e ABI (model 77): sale of real estate;
  - NFS-e Via: road tolls;
  - the NF-e cases with their own schedule: import (after the Duimp), monophasic fuels, and issuers that are not ICMS taxpayers;
  - the DeRE (Declaração de Regimes Específicos), the declaration of taxpayers in specific regimes.

  Import declarations filed in government systems (Duimp, DIR) are out of scope.
- **Taxes and regimes:** ICMS, ISS, IPI, CBS, IBS, IS with effective-dated rates; regular, Simples Nacional and MEI; specific and differentiated regimes.
- **Events:** every issuer and recipient event of each document, per RFC-0002 C-EVENTS (Brazil fiscal core), plus number voiding.
- **Purchase NF-e:** query of received documents and recipient acknowledgement (awareness, confirmation, unknown operation, operation not performed).
- **Numbering:** the Location's normal series plus a reserved series per machine.
- **Homologation behind a software credential:** once Akela holds a UF's software credential, homologate there the documents that were tested elsewhere for lack of it (Santa Catarina: NFC-e at SVRS, including the CSC and offline contingency).
- **Software credentials per UF:** every credential a UF requires of the issuing software or its developer, per RFC-0002 C-SOFTWARE-CREDENTIAL (software credentials), and the technical responsible party on every document. Santa Catarina requires a credentialed PAF-NFC-e developer for NFC-e (RICMS/SC Anexo 11, art. 95-A; Ato DIAT 54/2026), a credentialed PAF-BP-e developer for BP-e (Anexo 11, art. 168-B) and a credentialed system (CSPD) for NFCom (Anexo 7, art. 2); a credential obtained by 2027-07-30 may present its conformity report (LCL, valid 24 months) until 2028-11-30 (Ato DIAT 54/2026 Anexo I).
- **Contingency:** every mode per document (SVC, EPEC, FS-DA, offline), with the offline queue, automatic retries and deadline alerts.
- **NFS-e retries:** check by DPS ID before each retry.
- **Regression:** reference cases resent in homologation on each new Technical Note or schema package.
- **No cloud monitor yet:** the Location decides from the authorizer's own response.

**3.4 Location app backend.** Stock, rentals, finance and orders on top of the fiscal core, all exposed through an API. Done when every domain operation works through the API alone.

**3.5 Location operations.** Local backup and restore, rqlite and agent upgrades without downtime, and local alerts (disk, node down, no majority).

**3.6 Location app UI.** Dioxus desktop and web, consuming the Location app backend API (stock, rentals, finance and orders) built in 3.4.

**3.7 Mobile app on the Location network.** Dioxus mobile. The phone talks to a local node.

## 4. Cloud feasibility

**4.1 CDC → Consolidated Postgres + minimal Central Registry + schema migrations.** Done when a Location that was offline for days, or whose cluster was recreated, syncs without duplicates or losses, and receives the pending migration before resuming events.

**4.2 PKI (step-ca), scheme 3 (step-ca in the cloud).** Real enrollment with approval, automatic renewal, passive revocation and offline validation on Windows, plus the move from a Location's own step-ca (scheme 2) to the cloud step-ca (scheme 3). Done when a machine is enrolled, renews, is blocked and leaves the cluster automatically, and a Location with its own step-ca (scheme 2) moves to the cloud step-ca (scheme 3) without stopping.

**4.3 Order saga.** Expiring reservations across Locations, compensation and idempotency, with simulated payment (the payment provider is chosen later). Done when no failure combination yields a double reservation, a charge without stock, or a stuck reservation.

## 5. Cloud product

**5.1 Central Registry + CLI.** Customers, Locations, machines, roles and credentials, operated from the command line.

**5.2 Real Cloud Node.** Joins each Location Cluster and votes when the rules say it should.

**5.3 Fiscal authorizer monitor.** SSE feed to each Location, used as an auxiliary signal.

**5.4 Buyer merge.** Combines duplicate Buyer records across Locations.

**5.5 Cloud operations.** Backups, metrics, logs and alerts.

**5.6 Offering modes.** Self-hosted, multi-tenant SaaS, and cloud-only Locations; Locations under schemes 1 and 2 (no CA, or step-ca on a Location machine) need no cloud.

**5.7 Cloud web UI.** Administration, using the same API as the CLI.

**5.8 Location app via the cloud.** Browser and phone access from outside the Location network, through the Cloud Node.

**5.9 Website/storefront.** Reads the Consolidated Postgres and creates orders through the order saga built in 4.3 (expiring reservations across Locations, compensation, idempotency).
