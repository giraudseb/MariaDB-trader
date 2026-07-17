# MariaTrader

A native **macOS SwiftUI** trading-workload generator built to demonstrate
**MariaDB availability** through a **MaxScale** front-end. It drives a realistic
mixed read/write SQL workload against MaxScale and visualises, in real time:

- **Throughput & latency** — committed tx/s (reads vs writes) and p50/p95/p99 latency.
- **Failover continuity** — committed-vs-failed traffic, auto-reconnect, and a
  per-connection outage timeline with measured downtime windows.
- **Read/write split** — which backend node served reads vs writes (via
  `@@server_id` / `@@hostname`), proving MaxScale routing.
- **Connection-pool health** — live per-connection status, ops, errors,
  reconnects, and the node each connection is currently talking to.

It talks to MariaDB through the **MariaDB Connector/C** (`libmariadb`) via a thin
Swift wrapper — the same client library a real application would use.

## Architecture

```
Sources/
  CMariaDB/        C shim exposing <mysql.h> (libmariadb) to Swift
  TradingCore/     Engine — connection wrapper, worker threads, workload, metrics
    MariaConnection.swift   blocking libmariadb wrapper (1 per worker thread)
    WorkloadEngine.swift    N worker threads: mixed trade txns + market-data reads
    Schema.swift            trading schema DDL + seed (accounts/instruments/orders/trades)
    Metrics.swift           thread-safe metrics aggregator + per-second time series
  MariaTrader/     SwiftUI app (control bar, config, 5 dashboards, live log)
  SmokeTest/       headless harness that drives the engine for CI/verification
```

Each worker owns one connection (one MaxScale session). Reads (`SELECT`) are
routed by MaxScale's readwritesplit router to replicas; write transactions to
the primary. When a node dies, the blocking client call fails fast (short
connect/read/write timeouts), the worker records the outage, reconnects with
backoff, and MaxScale re-routes it to a healthy primary — which is exactly the
availability story the dashboards make visible.

## Requirements

- macOS 14+, Swift 6 / Xcode 26 (Swift toolchain).
- MariaDB Connector/C. This project auto-detects the Homebrew MariaDB install at
  `/opt/homebrew/opt/mariadb`. If yours differs, edit `mariadbPrefix` in
  `Package.swift`.

## Build & run

```bash
swift build
swift run MariaTrader        # launches the GUI
```

In the app: open **Config**, point **Host/Port** at your MaxScale listener
(default `127.0.0.1:4006`), set user/password/database, then **Start workload**.
Adjust read ratio and per-worker rate live from the control bar.

## MaxScale / MariaDB setup (the demo target)

Create the application account MaxScale will proxy (on the primary):

```sql
CREATE DATABASE trading;
CREATE USER 'app'@'%' IDENTIFIED BY 'app';
GRANT ALL PRIVILEGES ON trading.* TO 'app'@'%';
```

A minimal MaxScale `readwritesplit` service with a listener on port `4006`
pointed at your primary + replicas is all that's needed — the app creates its
own schema on first start.

## Demonstrating a failover

1. Start the workload and let TPS stabilise on the **Overview** tab.
2. Trigger a failover, e.g.:
   - stop the primary container/service, or
   - `maxctrl call command mariadbmon switchover <monitor> <newprimary> <oldprimary>`
3. Watch the **Failover** tab: a brief blip of failed transactions, an outage
   row with a measured downtime window (typically sub-second to a few seconds),
   then committed traffic resumes on the new primary. **Cumulative downtime**
   and **Availability %** quantify the impact.
4. The **Read/Write Split** and **Pool Health** tabs show traffic shifting to
   the surviving nodes.

## Headless verification

```bash
# Runs the real engine against a DB for 5s and asserts committed > 0.
DB_HOST=127.0.0.1 DB_PORT=3306 DB_USER=app DB_PASS=app DB_NAME=trading \
  RUN_SECONDS=5 WORKERS=6 swift run smoketest
```

> A single MariaDB node (no MaxScale) works for a functional test — you just
> won't see read/write splitting across nodes, since everything is one server.
