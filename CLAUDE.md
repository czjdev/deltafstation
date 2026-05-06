# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Run / Dev

```bash
# Dev (port 5000, debug=on, auto-reload off by default — see run.py)
python run.py

# To enable Flask reloader during dev:
FLASK_USE_RELOADER=1 python run.py

# Windows production (NSSM + nginx + waitress, see deploy/README.md)
.\deploy\windows\install.ps1
.\deploy\windows\upgrade.ps1
```

There is no test suite, no lint, no build step. Frontend is Jinja templates rendered by Flask; nothing to bundle.

## Architecture in 60 seconds

```
Flask app  (backend/app.py: create_app)
├── 7 blueprints under /api/*  (backend/api/*.py)
├── Jinja templates           (frontend/templates/*.html — NOT a SPA)
└── At startup:
    ├── live_data_manager.start()       background tick polling thread
    ├── xtdata.reconnect()              one-shot connect to miniQMT IPC (env MINIQMT_PORT)
    └── stdout is wrapped → in-process LogQueue → /api/logs/stream (SSE)

Each api/*.py is a thin Flask blueprint over a core/*.py engine. Engines wrap deltafq
(sister project at ../deltafq, see deltafq/ in same parent dir).

Storage is file-based — no DB:
  data/raw/<sym>.csv          downloaded historical bars
  data/strategies/<name>.py    user strategies (subclass deltafq.BaseStrategy)
  data/results/<id>.json       backtest results
  data/simulations/<id>.json   account configs + persisted state
```

## Critical invariants

1. **Single process, multi-thread only.** `live_data_manager` starts an in-process
   polling thread inside `create_app()`. SSE log streaming reads from a process-local
   `LogQueue` (`backend/app.py:24-49`). Multi-worker (`gunicorn --workers N`,
   `waitress --processes N`) will start the gateway N times and the SSE will only
   see one process's stdout. Production uses **`waitress` with multi-thread, single process**.

2. **Two independent xtquant APIs (don't conflate):**
   - `xtdata` = market data (live + historical). Talks to QMT via IPC port (default 58610).
     Configured in `backend/app.py` startup via `xtdata.reconnect('localhost', $MINIQMT_PORT)`.
     **MiniQMT mode listens on 58610** (`miniquote` process). **Full QMT (XtItClient) listens on 58600.**
   - `xttrader` = order placement. Goes through `userdata_mini` filesystem path,
     configured per-account in `data/simulations/<id>.json` (`qmt_path` field) — set by
     UI, not by deploy config.

3. **Trading page has two account modes** (`account_type` field on each saved account):
   - `local_paper` → `simulation_api` → `SimulationEngine` (in-memory tick matching)
   - `broker` → `broker_api` → `BrokerEngine` (real miniQMT, calls `xttrader.connect`)
   The frontend auto-routes to the right engine based on the loaded account.

4. **Multi-source data routing.** Every data fetch takes a `source` / `data_source`
   parameter (`yfinance` or `miniqmt`). `LiveDataManager` (singular) is actually
   `MultiSourceLiveDataManager` — it keeps one `SourceLiveDataManager` per source so
   switching sources doesn't tear down the other. The frontend's data-source toggle
   (`YF` / `QMT` button in `trader.html:72-73`, persisted in URL `?source=`) decides
   which one each request hits.

5. **AI Agent flow** (`backend/core/agent/`):
   - `llm_client.py` is OpenAI-compatible (configured for DeepSeek by default in
     `config/config.py:11-14`). API key is **hardcoded in config.py** — be careful
     when grepping for keys.
   - `skill_prompt.py` matches keywords in user message and prepends
     `skills/<name>/SKILL.md` to the system prompt. Currently only the `backtest` skill
     is wired in.
   - `tool_runner.py` runs the function-calling loop. Tools are registered in
     `tool_registry.py` via `TOOL_DEFINITIONS`; implementations live in `tools/`.

## Where things live

| Need to change | File |
|---|---|
| Add a REST endpoint | `backend/api/<area>_api.py` (Flask blueprint) |
| Change a backtest / live engine behavior | `backend/core/<area>_engine.py` (mostly delegates to `deltafq`) |
| Add an AI Agent tool (function call) | `backend/core/agent/tools/*.py` + register in `tool_registry.py` |
| Add an AI Agent skill (markdown injected into system prompt) | `backend/core/agent/skills/<name>/SKILL.md` + matcher in `skill_prompt.py` |
| Add a strategy | drop a `data/strategies/<name>.py` subclassing `deltafq.strategy.base.BaseStrategy` |
| Frontend page | `frontend/templates/<page>.html` + corresponding `frontend/static/js/<page>.js` |
| Production deploy scripts | `deploy/windows/*.ps1` + `deploy/windows/nginx.conf` |

## Sister project: deltafq

`deltafq` (PyPI: `deltafq>=1.0.2`, source likely at `../deltafq`) is the underlying
quant framework. `BacktestEngine`, `LiveEngine`, gateways (`MiniqmtPushGateway`,
`MiniqmtTradeGateway`, `YFinanceDataGateway`), strategy base class, indicators,
`xtdata` import wrappers — all live there. When debugging "why does backtest do X",
check `../deltafq/` first; deltafstation is mostly a Flask wrapper.

## Frontend gotchas

- Bootstrap 5 + vanilla JS + Chart.js, no framework. Each page has one matching
  `frontend/static/js/<page>.js` file.
- Data-source state (`yfinance` / `miniqmt`) is **per-page** and stored in URL
  `?source=` + localStorage. `setGlobalDataSource('miniqmt')` is the entry point.
- SSE endpoints (`/api/logs/stream`, `/api/ai/chat/stream`) require `proxy_buffering off`
  in nginx — see `deploy/windows/nginx.conf` for the working config.
- `trader.js:loadDailyKData` previously had a bug where it didn't pass `data_source`
  on POST — fixed on `feat/windows-deploy` branch. If touching K-line fetch code,
  ensure `data_source` is always forwarded.

## Production deployment

A complete Windows Server 2022 + 天翼云 deployment kit lives under `deploy/`. The
spec, plan, and post-mortem are at `docs/superpowers/specs/2026-05-05-windows-deploy-design.md`
and `docs/superpowers/plans/2026-05-05-windows-deploy.md`. Real-world gotchas
(UTF-8 BOM for PS 5.1 with Chinese, missing `TA-Lib` in requirements.txt, miniQMT
port differences) are in spec §13.

Server runs `waitress-serve --listen=127.0.0.1:8001 --threads=4 --call backend.app:create_app`
under NSSM (service name `DeltaFStation`), behind nginx on port 18081 with Basic Auth.
