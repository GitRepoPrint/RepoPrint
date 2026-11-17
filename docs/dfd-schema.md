# DFD graph schema (draft v1)

Status: **draft for discussion**. Nothing in the frontend or backend implements this yet.

## Why this exists

RepoPrint will produce a Data Flow Diagram (DFD) in two places:

| Producer | Runs in | Input | Purpose |
|---|---|---|---|
| **Overview** | browser / Chrome extension | a few config files (compose, Dockerfiles, manifests, config) | small architecture view: dashboard, extension |
| **Detail** | backend (`GET /dfd`) | the whole source tree (tree-sitter) | code-level view: full canvas |

They analyse different evidence, so they are complementary, not duplicates. To keep them from drifting
they both emit **this one schema**, and the two views are *projections* of it.

Today the two sides disagree (backend kinds `process | entity | datastore | external | queue`, positions
always `{0,0}`; frontend kinds `external | process | store` with hand-placed coordinates). This schema replaces both.

## Graph

```json
{
  "schema_version": "1",
  "repository": { "owner": "acme", "repo": "shop", "ref": "main" },
  "level": "overview",
  "nodes": [],
  "edges": [],
  "meta": { "producer": "browser-overview", "generated_at": "2026-11-14T10:00:00Z" }
}
```

- `level`: `"overview"` or `"detail"`, which producer made it. It is information, not a filter.
- `extra` (optional, detail only): producer-specific graph-level data. The backend puts `extra.flows` here, the
  per-route list of which resources each endpoint reaches (with file, line and call of each access).
- `meta.producer`: `"browser-overview"`, `"backend-detail"`, or `"combined"` (the client joined both; `meta.sources` lists them). Producer-specific stats (file counts, unsupported
  languages...) go in `meta`, never in nodes.

## Node

| Field | Required | Description |
|---|---|---|
| `id` | yes | Stable identifier, see *IDs*. |
| `kind` | yes | `external_entity` \| `process` \| `data_store`. The three classic DFD element types, nothing else. |
| `name` | yes | Short display name. |
| `technology` | no | Lower-case slug from the shared vocabulary: `postgresql`, `redis`, `kafka`, `nginx`, `http-api`, `stripe`... |
| `tags` | no | Free refinements: `queue`, `proxy`, `gateway`, `client`, `third-party`. |
| `parent` | no | `id` of a `process` node that contains this one. Only processes can be parents. |
| `path` | no | Repo-relative folder or file. This is the **join key** between overview and detail. |
| `provenance` | yes | See below. |
| `extra` | no | Producer-specific payload (detail: files, languages, routes, definitions...). The UI must not depend on it. |

### Kind mapping

| Concept | `kind` | Notes |
|---|---|---|
| Browser / user | `external_entity` | tag `client` |
| Third-party API or SaaS (Stripe, AWS...) | `external_entity` | tag `third-party`, `technology` set |
| Service in this repo | `process` | |
| Database, cache, file storage | `data_store` | |
| Message queue / broker | `data_store` | tag `queue` |
| Reverse proxy / gateway in this repo | `process` | tag `proxy` / `gateway` |

Old values: backend `entity`, `external` -> `external_entity`; `datastore`, `queue` -> `data_store`;
frontend `store` -> `data_store`, `external` -> `external_entity`.

### Provenance (borrowed from code2DFD's traceability)

```json
"provenance": {
  "source": "config",
  "confidence": "high",
  "evidence": [
    { "file": "docker-compose.yml", "line": 12, "span": 4 },
    { "note": "heuristic: image name 'postgres:16'" }
  ]
}
```

- `source`: `config` (overview), `code` (detail) or `manual` (added by the user in the canvas).
- `confidence`: `high` (stated explicitly), `medium` (strong convention), `low` (guess).
- `evidence`: at least one entry. Real location (`file`, optional `line`/`span`) or a `note` when it is a heuristic.
- **Never** put secret values in evidence. Config files such as `.env` may be read, but only host names and
  keys are kept (`DATABASE_HOST` -> `db`), never the value of a password or token.

## Edge

| Field | Required | Description |
|---|---|---|
| `id` | yes | `<source>-><target>:<label>` |
| `source`, `target` | yes | Node ids. Direction = who **initiates** the data flow (caller -> callee). |
| `label` | yes | Short human text: `reads/writes`, `HTTP requests`, `publishes`. |
| `operations` | no | Subset of `["read", "write"]`. |
| `protocol` | no | `http`, `sql`, `amqp`, `grpc`... |
| `provenance` | yes | Same shape as for nodes. |
| `extra` | no | Detail only (call counts, `via` modules, route lists). |

Rules: no self-loops; parallel edges with the same `(source, target, label)` are merged (that is what
`count` in `extra` is for).

## IDs

IDs must be stable between runs and shared by both producers, because threat findings (later) attach to node ids.

```
process:<path>                  process:services/api       (repository root: process:.)
data_store:<instance>           data_store:db              (a named instance, e.g. a compose service)
data_store:<technology>         data_store:postgresql      (anonymous, found only via a dependency)
external_entity:<host-or-name>  external_entity:api.stripe.com
external_entity:client          external_entity:client
```

**Merging rule** (done when combining an overview and a detail graph): an anonymous `data_store:<technology>`
merges into a named instance of the same technology **if exactly one exists**; if there are several, keep it
separate with `confidence: low`.

## Combining overview and detail

Neither producer depends on the other. The **client** combines two graphs with a pure function, `combineGraphs`
(`src/lib/dfd/combine.ts`). Nothing is dropped silently: when one side says something and the other does not, both stay.

1. **Same id, same node.** Merged: the overview's name, path and technology win; confidence is the higher one and the
   evidence lists are concatenated (overview first); each side's `extra` is kept and `extra.sources` says
   `["config", "code"]`.
2. **A store the code found, and a store the compose file names.** An anonymous `data_store:<technology>` (found
   through an import) joins the **one** named instance of the same technology (`data_store:db`); with several it
   stays apart, since it cannot tell which is meant. The vague `data_store:sql-database` (an ORM) joins the one known
   SQL database; `data_store:message-queue` (celery) joins the one known queue. Edges and the detail's `extra.flows`
   are re-pointed at the surviving node, and edges that become identical are merged (counts add, proofs add).
3. **Parents.** For each detail `process`, set `parent` to the overview component whose `path` is the **longest prefix**
   of its own `path` (at a folder boundary: `services` claims `services/api`, not `services-old`). Components nest the
   same way. `.` claims whatever no other component does. No match -> `parent` stays empty and it is shown as
   "unassigned". A component with the same id as a detail node is that node: kept once, still the parent of what is
   below it. **Detail folders nest in each other by path** (`src/flask/json` inside `src/flask`), below any component, so
   opening a component shows its first level and not every folder at once. The repository root folder (`.`) contains nothing.
4. **Edges** are joined by (source, target, label).

A vague label next to a precise one is folded in the **overview** view only (see below): the config says a service
`reads/writes` a database, the code says `reads`; the view shows `reads` with both proofs.

Checked on `dockersamples/example-voting-app`: the overview built from the real config files and the backend's real
detail graph give one PostgreSQL database (`db`, with the compose declaration and the code's imports as evidence),
every folder under the service built from it, and the folder nobody claims left visible.

## Views are projections

Both views come from the same graph; a view is a function, not a second analysis.

- **Overview view:** keep nodes with no `parent`. Edges whose endpoint is inside a component are *lifted* to the
  component, self-loops are dropped, and parallel edges (same source, target and label) are merged: counts add up,
  operations are unioned, the strongest confidence wins. A lifted edge labelled `imports` is **dropped**: it says
  "this code imports that code", not "data flows there". An edge that was not lifted keeps its label.
  After that, an edge labelled `reads/writes`, `accesses` or `publishes/consumes` disappears when the same pair also has
  a precise edge (`reads`, `writes`, `publishes`, `consumes`), and a `depends on` edge (a service waits for another at
  start-up, the weakest proof) disappears when the same pair has any other edge: the stronger one takes over its proofs.
  A generic client (a plain HTTP library, WebSocket, gRPC, JWT: `GENERIC_TECHNOLOGIES`) says how code talks, not with
  whom, so it is shown only for the **parts** of an opened component; at the component level its edge is dropped and the
  node disappears if nothing visible reaches it.
  **Focus (enforced limit):** a big repository can have hundreds of components, so the UI never draws more than
  `MAX_FOCUS_NODES = 10` at once unless the user asks for the whole diagram (`src/lib/dfd/focus.ts`). Three modes:
  *main flow* (default), *choose components* (the user ticks them, also at most 10) and *whole diagram* (no limit).
  The main flow starts at the busiest component and keeps adding the best-ranked one that connects to what is already
  there. Rank = connections (data flow counts 3, `imports` counts 1) + a bonus for the client (8), data stores (5) and
  external systems (2); tests, docs, examples, scripts and benchmarks are ranked last. The parts of a component the
  user opened and the selected component get priority. A kind filter (processes / data stores / external), a text
  search and a sort (most connected / name / type) narrow the list. The focus is a function over the view, like
  expanding; it changes nothing in the graph.
- **Detail view:** all nodes and every edge exactly as given; components are drawn as groups containing their children.
- **Expanding** is a set of open component ids. A node is visible when all its ancestors are open; an edge attaches
  to the nearest visible ancestor of each end. Overview = nothing open, detail = everything open, and opening every
  component that has parts shows exactly the detail view's nodes. A part is drawn tied to its opened parent by a dotted
  containment stroke, and a closed component with parts carries a `+n` mark.
- A `parent` that does not exist or is not a `process`, or that would form a cycle, is ignored (the node stays visible).

Used by: dashboard tab and extension -> the same overview view; full canvas -> detail (overview first, expand on demand).

## What is NOT in the schema

These are presentation or analysis concerns and are derived on the client:

- `x`, `y`, handles: computed by the layout (Dagre). User edits are stored as a separate **user overlay** (see *Decisions*), keyed by node id.
- `code` (`PR-003`): generated from order or kind.
- `subtitle`: derived from `kind` and `technology`.
- `classification`, `findingIds`, severities: belong to the future STRIDE/LINDDUN output, which references node ids.

## Overview v1 (built)

Code: `RepoPrint-Frontend/src/lib/dfd/overview/`. Config-only, no source parsing, runs in the browser or the extension.

**Fetching** (`fetch.ts`): one call to `api.github.com/.../git/trees/HEAD?recursive=1` for the file list, then each chosen
file from `raw.githubusercontent.com`. Both send `access-control-allow-origin: *` (checked), so a page can call them;
`codeload.github.com` (the tarball the backend uses) does not, which is why whole-repo analysis stays in the backend.
Unauthenticated API calls are limited to 60 per hour (one per overview); the raw requests showed no rate-limit headers.
Raw requests carry no custom headers, so there is no CORS preflight. Real runs: 2 to 22 requests, 0.3 to 1.3 s.

**Files read** (`select.ts`): compose, Dockerfiles, manifests (`package.json`, `pyproject.toml`, `requirements.txt`,
`pom.xml`, `build.gradle(.kts)`, `go.mod`, `Cargo.toml`) and config (`application.yml/.properties`, `.env.example`).
Not under `node_modules`, `vendor`, `docs`, `examples`, tests and the like. Caps: 6 compose, 20 Dockerfiles, 12 config,
30 manifests. Compose files: only the shallowest folders, never `*.test.*` / `*.ci.*` / `*.e2e.*`, base first and then
overrides, up to 3 per folder; the overrides are merged into the base (`mergeServices`), because some services exist
only there. A plain `.env` is not read (only `.env.example`/`.sample`/`.template`).

**Components**
1. A compose service is a process, or a data store when its image (`postgres`, `redis`, `rabbitmq`...) or its Dockerfile's
   base image says so (the latter at medium confidence). Proxies (`nginx`, `traefik`...) are processes tagged `proxy`.
2. A built service's `path` is the folder of its code: the build context, or the Dockerfile's folder when the Dockerfile
   is called `Dockerfile` or `Dockerfile.<variant>` and sits inside the context (`context: .` with
   `backend/Dockerfile` is `backend`).
3. A service that only names an `image:` takes the folder named like the image, then like the service, then ending in
   `-<service>`, only when exactly one folder fits (medium confidence, with a heuristic note). This finds
   `springcommunity/spring-petclinic-vets-service` -> `spring-petclinic-vets-service/`.
4. With no compose services: each folder with a manifest that **runs** is a component (it has a web framework, a
   Dockerfile, sits under `apps/`, `services/`, `servers/` or `cmd/`, or is a root folder like `backend`). Libraries and
   tooling are not components. If nothing runs, one `Application` (named after the repo, path `.`).

**Edges**
- Compose `depends_on` / `links` -> `depends on` (process to process) or the data store's label; medium confidence.
- Addresses in environment variables and config files that match a compose service name -> `calls` or the store's label;
  high confidence. Only the host, port, scheme and key name are kept, never the value (tested: no credential reaches the
  graph). Multi-document YAML (Spring profiles) is read in full.
- Production dependencies the catalog knows: databases and queues -> `reads/writes` / `publishes/consumes`; named external
  services (Stripe, Sentry...) -> `calls`; generic ones (a plain HTTP client, WebSocket, gRPC, JWT) are ignored. Test and
  development dependencies are ignored. A dependency name is also tried with `-` replaced by `_`, `.` and `/`
  (`psycopg2-binary`, `azure-storage-blob`), plus a short alias table for Python and Spring names.
- A component also gets what the workspace libraries it depends on use (matched by manifest name, any depth, loops safe),
  except for the web-framework test, which only looks at its own manifests.
- A database found only through a dependency joins the single compose instance of the same technology; with several
  instances it stays a separate low-confidence node. An ORM dependency (`sql-database`) joins the single known SQL database
  and is resolved after all specific ones, so the result does not depend on reading order.
- Client -> component: `HTTP requests` for a component with a web framework (server frameworks from the catalog, plus
  web frontends such as `react-dom`, `vue`, `vite`, and Spring Cloud Gateway). A published port (or an `EXPOSE`
  outside compose) is a weak signal, because development stacks publish everything: it only makes a `network access`
  edge when **no** component is known to answer HTTP, or when the component is a proxy. A database that only publishes
  a port for developers is never exposed.
- Skipped: compose services that only test the system (a word such as `test`, `e2e`, `playwright`, `cypress`, `selenium`
  or `sut` in the service name or in the image path, ignoring the registry and the tag).

**Known limits** (seen on real repositories)
- A stack of eleven services (Spring Petclinic) is still a busy picture, even after the client fan-out and the
  `depends on` duplicates are gone: that is the size of the system. The detail is where the expand/collapse of
  components will help.
- `.NET`, Ruby, PHP and Swift manifests are not read; `build.gradle` version catalogs (`libs.xxx`) and Kubernetes, Helm,
  Terraform and `nginx.conf` are not read either.
- The catalog's name matching can false-positive on look-alikes (`mongo-express`, `redis-commander`).
- Provenance carries the file and line where something was declared; the confidence is a judgement, not a measurement.

**Tested on**: `dockersamples/example-voting-app` (4 services, 2 stores, client), `fastapi/full-stack-fastapi-template`
(compose + override, root build context), `spring-petclinic/spring-petclinic-microservices` (image-only services,
multi-document `application.yml`, `lb://` routes), `t3-oss/create-t3-turbo` (workspace, no compose), `pallets/flask`
(no config: one `Application`).

## Shared vocabulary

The dependency -> technology mapping (301 module names in 27 entries: PostgreSQL, Redis, Kafka, Stripe, AWS...) lives in
**one JSON file with two copies**, because the backend and the frontend are separate repositories:

- `RepoPrint-Backend/app/services/dfd_catalog.json` (read by `dfd_catalog.py`)
- `RepoPrint-Frontend/src/lib/dfd/catalog.json` (read by `catalog.ts`)

Each entry has a `category` (`datastore`, `external`, `queue`, `entrypoint`), a `label`, a `technology` slug (the one used
in node ids: `data_store:postgresql`) and its `modules`. Order matters: the first match wins.

Keeping the copies equal:
1. Edit one copy, copy it over the other.
2. `scripts/check-catalog-sync.sh` (repository root) fails if they differ.
3. Regenerate the parity file, which holds the backend's answers for about 1,200 probes, with
   `uv run python scripts/export_catalog_golden.py ../RepoPrint-Frontend/src/lib/dfd/__fixtures__/catalog-golden.json`
   (from `RepoPrint-Backend`). The frontend test fails if its `classify()` ever disagrees with the backend's.

## Status

- **Backend (done):** `GET /dfd` emits this schema (`level: "detail"`). The old internal graph is converted in
  `app/services/dfd_schema.py`. Known limits: `parent` is always empty (matching is done by the client), and for
  nodes other than processes the evidence is a note ("seen via psycopg2"), not yet a file and line.
- **Frontend, view logic (done):** `src/lib/dfd/schema.ts` (types and a runtime check, `isDfdGraph`) and
  `src/lib/dfd/project.ts` (`overviewView`, `detailView`, `project` with expanded components, and `assignParents`),
  tested on hand-built graphs and on a real Flask graph (`src/lib/dfd/__fixtures__/flask-detail.json`, produced by the
  backend). Not connected to any page yet.
- **Shared catalog (done):** one JSON file, two copies, a sync script and a golden-file parity test (see *Shared vocabulary*).
- **Combining (done):** `src/lib/dfd/combine.ts`, with the shared provenance rule in `src/lib/dfd/provenance.ts`.
  Tested on hand-built graphs and on a real pair (voting app).
- **Hostile inputs (done):** every parser is tested against files made to hurt (alias bombs, quadratic regex inputs,
  huge or deeply nested files); one file that cannot be read is skipped and listed in `meta.unreadable`.
- **Overview producer (done, not yet in any page):** `src/lib/dfd/overview/` (see *Overview v1*). Adds the `yaml` and
  `smol-toml` dependencies.
- **Frontend, UI (done for the dashboard tab):** for a real repository the dashboard's DFD tab and the full canvas show the
  **overview**, inferred in the browser (`useRepositoryDfd` -> `getOverview` -> `overviewView` -> `graphToDfdModel`, with a
  10-minute cache in `localStorage`, because the GitHub API allows 60 unauthenticated requests per hour). The tab has
  loading, error and "partial" states, and shows for the selected component where it was inferred from (file and line,
  linked to GitHub), how sure the producer is, and, once the code analysis is in, facts about the code (files, languages,
  routes). The demo repositories (the fake `deti-org/...` ones) keep their mock diagram.
- **Code-level detail in the tab (done, optional):** with `NEXT_PUBLIC_BACKEND_URL` set, an "Add code-level detail" button
  asks the backend for `GET /dfd` (`fetchDetailGraph`: validated, errors translated to English, 2-minute timeout,
  10-minute in-memory cache), joins it with `combineGraphs`, and lets the user open each component ("Show n parts",
  "Expand all", "Collapse all"). Without the setting the button is not shown. The backend now has CORS
  (`CORS_ORIGINS`, GET only, no credentials), checked with real preflight requests.
- **Repositories list (done):** a newly associated repository shows "Analyze now"; clicking it runs the in-browser analysis,
  stores `analyzedAt` and opens the dashboard on the diagram. The list then says "Not scored yet" (there is no security score
  until the threat analysis exists). For a real repository the dashboard opens on the DFD tab, and the sample-data tabs
  carry a notice. A repository whose configuration has no services (one `Application`) asks the backend for the code-level
  detail by itself and opens the `Application` to its first level.
- **Out of the MVP (decided with the team):** the editable canvas (and with it the code-level detail in the canvas, the "user
  overlay" for edits and the evidence in the canvas inspector) and the browser extension. Not done on purpose.
- **Not done:** the Threats tab, report and findings are still mock data, not linked to the real components.
- **Backend `/dfd` protections (done):** result cache (10 min), per-client rate limit on new analyses (`429` +
  `Retry-After`), a cap on concurrent analyses (`503` when no slot frees up in time), and `X-Forwarded-For` only when
  trusted. The frontend turns `429`/`503` into "try again" messages. Still missing: authentication (every client is
  anonymous) and shared limits across several backend processes.
- **Not wired (older note):** the dashboard and canvas used the mock `DfdModel`. Merging of identical node ids
  (confidence, evidence) is not implemented; it arrives with the overview producer.

## Migration notes

Backend: map its current kinds to the three canonical ones, add `parent`, `provenance`, `schema_version`, stop emitting
positions, move `files`, `definitions`, `routes`, `html` and `via` into `extra`.

Frontend: `DfdModel`, `DfdNodeData` and `Diagram` stop carrying coordinates, codes and findings; the canvas reads
the schema, runs the layout, and keeps the user overlay in `localStorage`, keyed by repository.

## Decisions

- **`queue` stays a tag** on a `data_store`, not a fourth kind.
- **User overlay key: repository only.** The overlay holds everything the user edits in the canvas: node positions,
  manually added nodes and edges (`source: manual`), removals and renames. Because node ids are stable, it is re-applied
  after every new analysis: surviving nodes keep their positions, new nodes get an automatic layout, and edits for nodes
  that no longer exist are ignored.
- **The dashboard preview and the extension use the same overview view**, built by the same projection function.
  Only the container differs (and the extension may show it smaller).
