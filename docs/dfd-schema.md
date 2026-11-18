# DFD graph schema (v1)

RepoPrint builds a Data Flow Diagram in two places. Both emit **this one schema**, and every view is a projection of it.

| Producer | Runs in | Input | Level |
|---|---|---|---|
| **Overview** | browser | a few config files (compose, Dockerfiles, manifests, config) | `overview` |
| **Detail** | backend, `GET /dfd` | the source tree (tree-sitter) | `detail` |

Code: `RepoPrint-Frontend/src/lib/dfd/` (`schema.ts` has the types and `isDfdGraph`) and `RepoPrint-Backend/app/schemas/dfd.py`. If one changes, the other changes.

## Graph

```json
{ "schema_version": "1", "repository": { "owner": "acme", "repo": "shop", "ref": "main" },
  "level": "overview", "nodes": [], "edges": [],
  "meta": { "producer": "browser-overview", "generated_at": "2026-11-14T10:00:00Z" } }
```

- `meta.producer`: `browser-overview`, `backend-detail` or `combined` (joined on the client). Producer stats go in `meta`, never in nodes.
- `meta.stats` (detail): `files_found`, `files_parsed`, `sampled` (a very large repository: only a sample was read), `listing_truncated`, `fetch_method` (`graphql`, `tree` or `archive`).
- `extra` (optional, detail): producer-specific data, e.g. `extra.flows`, the resources each route reaches.

## Node

| Field | Req. | Description |
|---|---|---|
| `id` | yes | Stable, see *IDs*. |
| `kind` | yes | `external_entity` \| `process` \| `data_store`. Nothing else. |
| `name` | yes | Short display name. |
| `technology` | no | Slug from the shared vocabulary: `postgresql`, `redis`, `http-api`, `stripe`... |
| `tags` | no | `queue`, `proxy`, `gateway`, `client`, `third-party`. |
| `parent` | no | `id` of a `process` that contains this node. |
| `path` | no | Repo-relative folder or file: the **join key** between overview and detail. |
| `provenance` | yes | See below. |
| `extra` | no | Producer payload (files, languages, routes). The UI must not depend on it. |

| Concept | `kind` | Notes |
|---|---|---|
| Browser / user | `external_entity` | tag `client` |
| Third-party API or SaaS | `external_entity` | tag `third-party` |
| Service in this repo | `process` | tag `proxy` / `gateway` for a reverse proxy |
| Database, cache, file storage | `data_store` | |
| Message queue / broker | `data_store` | tag `queue` (a tag, not a fourth kind) |

### Provenance

```json
"provenance": { "source": "config", "confidence": "high",
  "evidence": [ { "file": "docker-compose.yml", "line": 12, "span": 4 }, { "note": "image name 'postgres:16'" } ] }
```

- `source`: `config` (overview), `code` (detail) or `manual`. `confidence`: `high` (stated), `medium` (strong convention), `low` (guess).
- `evidence`: at least one entry, a real location or a `note` for a heuristic.
- **Never** put secret values in evidence: from `.env`-like files only host names and keys are kept (`DATABASE_HOST` -> `db`), never a password or token.

## Edge

| Field | Req. | Description |
|---|---|---|
| `id` | yes | `<source>-><target>:<label>` |
| `source`, `target` | yes | Node ids. Direction = who **initiates** the flow. |
| `label` | yes | `reads/writes`, `HTTP requests`, `calls`, `imports`... |
| `operations`, `protocol` | no | Subset of `["read","write"]`; `http`, `sql`, `amqp`... |
| `provenance`, `extra` | yes / no | As for nodes. `extra`: counts, `via`, routes, `bidirectional`. |

No self-loops. Parallel edges with the same `(source, target, label)` are merged.

## IDs

Stable between runs and shared by both producers.

```
process:<path>                  process:services/api       (repository root: process:.)
data_store:<instance>           data_store:db              (a named instance, e.g. a compose service)
data_store:<technology>         data_store:postgresql      (anonymous, found only via a dependency)
external_entity:<host-or-name>  external_entity:api.stripe.com
external_entity:client
```

## Combining overview and detail

`combineGraphs` (`src/lib/dfd/combine.ts`) is a pure function on the client. Nothing is dropped silently.

1. **Same id = same node.** The overview's name, path and technology win; confidence is the higher one; evidence is concatenated.
2. **Stores.** An anonymous `data_store:<technology>` joins the **one** named instance of that technology; with several it stays apart. `sql-database` (an ORM) joins the one known SQL database, `message-queue` the one known queue. Edges are re-pointed and merged.
3. **Parents.** A detail `process` gets as `parent` the overview component whose `path` is the **longest prefix** of its own (at a folder boundary). Detail folders nest by path below any component, so opening a component shows its first level. No match: no parent.
4. **Edges** are joined by `(source, target, label)`.

## Views are projections

A view is a function of the graph, not a second analysis.

- **Overview view:** nodes with no `parent`; edges inside a component are lifted to it, self-loops dropped, parallel edges merged. A lifted `imports` edge is dropped. A vague label (`reads/writes`) gives way to a precise one (`reads`) for the same pair; `depends on` gives way to anything. A generic client (`GENERIC_TECHNOLOGIES`) shows only for the parts of an opened component.
- **Detail view:** every node and edge; components drawn as groups.
- **Expanding** = a set of open component ids. A node is visible when its ancestors are open; an edge attaches to the nearest visible ancestor of each end. An invalid `parent` (missing, not a `process`, a cycle) is ignored.

### Big graphs (`src/lib/dfd/focus.ts`, `declutter.ts`)

- **Dashboard overview:** at most **10 components** (enforced), fewer if the main flow is smaller; always fitted to its box, with zoom buttons.
- **Full canvas:** no limit. Modes: *main flow* (default), *choose components*, *whole diagram*; filter by kind, search, sort; **detail level** (levels of folders open: 1, 2 (default), 3, all; deeper folders fold into their parent).
- **Main flow:** every component on a path from an *entry* (code that receives client requests) to a *destination* (data stores, outside systems and the code touching them), plus those ends and the client. Without entries (a library): the code that touches data. If nothing touches data: the 10 best-connected. A graph of 10 or fewer is shown whole.
- **Ranking** (for the 10 and the list): connections (data flow counts 3, `imports` 1) plus a bonus for the client (8), data stores (5), outside systems (2). The overview keeps at most 3 outside sites that were only found in a URL.
- **Tests, docs, examples, scripts** (`tests`, `docs_src`, `examples`, `scripts`, `benchmarks`, `test_*`...) are removed for both views, with whatever only they used. Only code-analysis nodes are touched; a compose service called `docs` stays. (FastAPI: 229 components -> 18.)
- **Fewer lines:** an `imports` edge already implied by a longer path is dropped; two-way `imports` become one line with two arrowheads; a data-flow edge is never dropped. Reachability never changes. Dependencies are drawn thin and dashed without a label, flows firm and labelled.

## Not in the schema

Presentation and analysis concerns, derived on the client: `x`, `y` and handles (Dagre layout), `code` (`PR-003`), `subtitle`, and `classification` / `findingIds` / severities (future STRIDE/LINDDUN output, which references node ids).

## Overview producer (`src/lib/dfd/overview/`)

Config only, no source parsing, runs in the browser.

**Fetching:** one `git/trees/HEAD?recursive=1` call, then each chosen file from `raw.githubusercontent.com` (both allow CORS; the tarball does not, so whole-repo analysis stays in the backend). Unauthenticated API: 60 calls per hour.

**Files read:** compose, Dockerfiles, manifests (`package.json`, `pyproject.toml`, `requirements.txt`, `pom.xml`, `build.gradle(.kts)`, `go.mod`, `Cargo.toml`) and config (`application.yml/.properties`, `.env.example`; never a plain `.env`). Not under `node_modules`, `vendor`, `docs`, tests. Caps: 6 compose, 20 Dockerfiles, 12 config, 30 manifests; compose overrides merge into their base.

**Components**
1. A compose service is a process, or a data store when its image or Dockerfile base says so; proxies are processes tagged `proxy`.
2. A built service's `path` is its build context (or the Dockerfile's folder). An `image:`-only service takes the folder named like the image or the service, if exactly one fits.
3. With no compose services, each folder with a manifest that **runs** (web framework, Dockerfile, under `apps/`, `services/`, `cmd/`...) is a component; if none, one `Application` (path `.`).

**Edges**
- `depends_on` / `links` -> `depends on`. Addresses in env vars and config matching a service name -> `calls` (high); only host, port, scheme and key are kept.
- Production dependencies the catalog knows: databases and queues (`reads/writes`, `publishes/consumes`), named external services (`calls`). Generic clients and test/dev dependencies are ignored.
- Client -> component: `HTTP requests` for a component with a web framework. A published port is a weak signal (`network access` only if nothing is known to answer HTTP, or for a proxy).
- Compose services that only test the system (`test`, `e2e`, `cypress`...) are skipped.

**Limits:** .NET, Ruby, PHP, Swift, Gradle version catalogs, Kubernetes, Helm, Terraform and `nginx.conf` are not read; catalog matching can false-positive on look-alikes (`mongo-express`); a large compose stack is still a busy picture.

## Shared vocabulary

The dependency -> technology catalog (module names grouped as PostgreSQL, Redis, Kafka, Stripe...) is **one JSON file with two copies** (the repositories are separate): `RepoPrint-Backend/app/services/dfd_catalog.json` and `RepoPrint-Frontend/src/lib/dfd/catalog.json`. Each entry has `category` (`datastore`, `external`, `queue`, `entrypoint`), `label`, `technology` (the slug in node ids) and `modules`. The first match wins.

Keeping them equal: edit one and copy it over the other; `scripts/check-catalog-sync.sh` fails if they differ; regenerate the parity file with `uv run python scripts/export_catalog_golden.py ../RepoPrint-Frontend/src/lib/dfd/__fixtures__/catalog-golden.json` (from `RepoPrint-Backend`). The frontend test fails if its `classify()` disagrees with the backend's.

## Status

- **Done:** both producers, `combineGraphs`, the views, the shared catalog, the dashboard DFD tab and full canvas, the `/dfd` guards (cache, rate limit, concurrency cap).
- **Known gaps:** the backend leaves `parent` empty (the client assigns it) and its non-process evidence is a note ("seen via psycopg2"), not a file and line. `/dfd` has no authentication yet. The Threats tab and report are still mock data.
- **Out of the MVP (decided with the team):** editing the diagram (the "user overlay": positions, manual nodes and edges, keyed by repository and node id) and the browser extension.
