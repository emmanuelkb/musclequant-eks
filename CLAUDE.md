# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

MuscleQuant AI — a single-file Flask app (`app.py`) that streams surface-EMG data from a MyoWare 2.0 sensor on an ESP32 (115200 baud) and renders a real-time dashboard plus a styled HTML session report. Built as a CS581 signature project.

## Run

```bash
pip install flask pyserial
python3 app.py     # http://localhost:8080
```

There is no `requirements.txt`, no test suite, no linter config, and no build step. The app binds 0.0.0.0:8080 with `debug=False`.

## Repo layout quirk (read before editing)

`app.py` calls `render_template('login.html')` and `render_template('index.html')`, but the HTML files live at the **repo root**, not in `templates/`. Flask's default loader looks in `./templates/`, so the app as-checked-in will 500 on any page render until `index.html` and `login.html` are placed under `templates/` (or `app = Flask(__name__, template_folder='.')` is set). When making changes, preserve whichever convention is in effect — don't silently move files.

`DATA_DIR` (`./data/`) is auto-created on startup and holds `users.json` plus per-session JSON dumps (`session_<user>_<timestamp>.json`).

## Architecture

Three layers, all in one process:

1. **Serial ingest** (`find_port` / `connect_serial` / `get_emg_value`) — auto-detects COM7 first, then any USB/CP210/CH340 port. If no port is found or the read fails, the app silently falls back to **simulation mode** (sine wave + noise). The `connected` global is set once at import time, so plugging the sensor in after startup requires a restart. EMG values are 12-bit ADC ints (0–4095) derived from millivolts the firmware emits.

2. **Stateful EMG processing** (module-level globals: `emg_history`, `rep_count`, `last_above`, `work_samples`, `rest_samples`, `current_state`). All processing is **per-process, single-user, in-memory** — there is no database for session metrics, and concurrent users would share/corrupt these counters. `WORK_THRESHOLD = 1200` is the single tunable that drives rep counting and work/rest classification.

3. **Auth + JSON API** — file-backed users in `data/users.json` with SHA-256 (unsalted) password hashes. Two decorators: `@login_required` for HTML routes (redirects to `/login`), `@api_auth` for `/api/*` routes (returns 401 JSON). Session cookies use a hardcoded `app.secret_key`.

The frontend (`index.html`) polls `/api/data` on an interval; each call advances all the stateful counters above as a side effect, so opening two browser tabs will double-count reps. `/api/clear` resets everything except `users.json`.

`/api/generate_report` either accepts a CSV upload (recomputes reps/fatigue/work-rest from the file) or a JSON body (uses live-session metrics) and returns a fully self-contained HTML report string with inline CSS — no template file involved. When editing the report, note that all styling is concatenated Python strings; muscle-specific coaching tips live in the `tips_map` dict and the badge/bar color thresholds are duplicated across `pk_col`/`av_col`/`ft_col`/`wk_col`.

## Things to watch

- The simulation fallback is silent — if you're debugging "why are my numbers wrong," check `connected` / the startup banner first.
- Rep counting is edge-triggered on `value > WORK_THRESHOLD`; lowering the threshold inflates rep counts retroactively because `emg_history` is just a 200-sample deque, not a per-rep log.
- `csv_log` grows unbounded for the lifetime of the process (only `/api/clear` empties it).