"""
MuscleQuant AI — API service (frontend + EMG ingest + auth).
Calls report-gen microservice for PDF/HTML report rendering.
"""
import csv
import hashlib
import io
import json
import math
import os
import random
import time
from collections import deque
from datetime import datetime
from functools import wraps

import requests
import serial
import serial.tools.list_ports
from flask import (
    Flask,
    Response,
    jsonify,
    redirect,
    render_template,
    request,
    session,
    url_for,
)
from sqlalchemy import (
    Column,
    DateTime,
    String,
    create_engine,
)
from sqlalchemy.orm import declarative_base, sessionmaker

# ── Config ──
DB_URL = os.environ.get("DATABASE_URL", "sqlite:///./local.db")
SECRET_KEY = os.environ.get("SECRET_KEY", "musclequant-dev-only")
REPORT_GEN_URL = os.environ.get("REPORT_GEN_URL", "http://localhost:8081")
SERIAL_PORT = os.environ.get("SERIAL_PORT", "AUTO")
BAUD_RATE = int(os.environ.get("BAUD_RATE", "115200"))
WORK_THRESHOLD = int(os.environ.get("WORK_THRESHOLD", "1200"))

app = Flask(__name__)
app.secret_key = SECRET_KEY

# ── DB ──
engine = create_engine(DB_URL, pool_pre_ping=True, future=True)
SessionLocal = sessionmaker(bind=engine, expire_on_commit=False)
Base = declarative_base()


class User(Base):
    __tablename__ = "users"
    username = Column(String(64), primary_key=True)
    name = Column(String(255))
    firstname = Column(String(100))
    lastname = Column(String(100))
    password_hash = Column(String(64), nullable=False)
    age = Column(String(10))
    email = Column(String(255))
    created_at = Column(DateTime, default=datetime.utcnow)


def init_db(retries: int = 30, delay: float = 2.0) -> None:
    last = None
    for _ in range(retries):
        try:
            Base.metadata.create_all(engine)
            return
        except Exception as e:
            last = e
            time.sleep(delay)
    raise RuntimeError(f"DB unreachable after retries: {last}")


def hash_pw(pw: str) -> str:
    return hashlib.sha256(pw.encode()).hexdigest()


# ── Serial / EMG (unchanged behavior) ──
ser = None
emg_history: deque = deque(maxlen=200)
start_time = time.time()
csv_log: list = []
rep_count = 0
last_above = False
work_samples = 0
rest_samples = 0
current_state = "REST"


def find_port():
    ports = list(serial.tools.list_ports.comports())
    for p in ports:
        if p.device.upper() == "COM7":
            return p.device
    for p in ports:
        if any(k in (p.description or "").lower() for k in ["usb", "cp210", "ch340"]):
            return p.device
    return ports[0].device if ports else None


def connect_serial() -> bool:
    global ser, SERIAL_PORT
    port = find_port()
    if not port:
        print("  SIMULATION mode (no serial port).")
        return False
    try:
        ser = serial.Serial(port, BAUD_RATE, timeout=1)
        time.sleep(2)
        SERIAL_PORT = port
        print(f"  Connected on {port}")
        return True
    except Exception as e:
        print(f"  Serial error: {e}. SIMULATION mode.")
        return False


connected = connect_serial()


def get_emg_value():
    global ser, connected
    if connected and ser:
        try:
            line = ser.readline().decode("utf-8", errors="ignore").strip()
            if line:
                for t in line.replace(",", " ").split():
                    try:
                        mv = float(t)
                        adc = int((mv / 3300.0) * 4095)
                        return max(0, min(4095, adc)), f"{mv:.6f}"
                    except ValueError:
                        pass
        except Exception:
            connected = False
    t = time.time() - start_time
    adc = max(
        0,
        min(4095, int(600 + 1800 * abs(math.sin(t * 0.4)) + random.randint(-120, 120))),
    )
    return adc, f"{round((adc / 4095.0) * 3300.0, 6):.6f}"


def calc_intensity(v):
    p = int((v / 4095) * 100)
    if v < 500:
        return "Rest", p
    if v < 1200:
        return "Low", p
    if v < 2400:
        return "Moderate", p
    if v < 3200:
        return "High", p
    return "Peak", p


def calc_fatigue(h):
    if len(h) < 40:
        return "Insufficient Data", 0
    d = list(h)
    half = len(d) // 2
    f = sum(d[:half]) / half
    s = sum(d[half:]) / half
    if f == 0:
        return "Normal", 0
    drop = ((f - s) / f) * 100
    if drop > 15:
        return "Fatigued", int(drop)
    if drop > 8:
        return "Mild Fatigue", int(drop)
    return "Normal", max(0, int(drop))


def update_reps(v):
    global rep_count, last_above
    above = v > WORK_THRESHOLD
    if above and not last_above:
        rep_count += 1
    last_above = above
    return rep_count


def update_wr(v):
    global work_samples, rest_samples, current_state
    if v > WORK_THRESHOLD:
        work_samples += 1
        current_state = "WORK"
    else:
        rest_samples += 1
        current_state = "REST"
    total = work_samples + rest_samples
    wp = int((work_samples / total) * 100) if total > 0 else 0
    flag = (
        "Overworking"
        if wp >= 80
        else "Too Much Rest"
        if 100 - wp >= 80
        else "Good Balance"
    )
    return wp, 100 - wp, current_state, flag


# ── Auth ──
def login_required(f):
    @wraps(f)
    def d(*a, **k):
        if "user" not in session:
            return redirect(url_for("login_page"))
        return f(*a, **k)

    return d


def api_auth(f):
    @wraps(f)
    def d(*a, **k):
        if "user" not in session:
            return jsonify({"error": "Not logged in"}), 401
        return f(*a, **k)

    return d


@app.route("/login", methods=["GET"])
def login_page():
    if "user" in session:
        return redirect(url_for("index"))
    return render_template("login.html")


@app.route("/login", methods=["POST"])
def do_login():
    d = request.get_json() or {}
    u = (d.get("username") or "").strip().lower()
    p = (d.get("password") or "").strip()
    if not u or not p:
        return jsonify({"status": "error", "message": "Please enter username and password"}), 400
    with SessionLocal() as db:
        user = db.get(User, u)
        if not user:
            return jsonify({"status": "error", "message": "Account not found. Create an account first."}), 401
        if user.password_hash != hash_pw(p):
            return jsonify({"status": "error", "message": "Wrong password. Please try again."}), 401
        session["user"] = u
        session["name"] = user.name or ""
        session["email"] = user.email or ""
        return jsonify({"status": "ok", "user": u, "name": user.name or u})


@app.route("/register", methods=["POST"])
def do_register():
    d = request.get_json() or {}
    fn = (d.get("firstname") or "").strip()
    ln = (d.get("lastname") or "").strip()
    u = (d.get("username") or "").strip().lower()
    p = (d.get("password") or "").strip()
    ag = (d.get("age") or "").strip()
    em = (d.get("email") or "").strip().lower()
    if not fn or not u or not p:
        return jsonify({"status": "error", "message": "First name, username and password are required"}), 400
    if len(p) < 6:
        return jsonify({"status": "error", "message": "Password must be at least 6 characters"}), 400
    with SessionLocal() as db:
        if db.get(User, u):
            return jsonify({"status": "error", "message": "Username already taken"}), 409
        name = (fn + " " + ln).strip()
        user = User(
            username=u,
            name=name,
            firstname=fn,
            lastname=ln,
            password_hash=hash_pw(p),
            age=ag,
            email=em,
        )
        db.add(user)
        db.commit()
        return jsonify({"status": "ok", "name": name})


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login_page"))


@app.route("/")
@login_required
def index():
    return render_template("index.html")


# ── EMG API ──
@app.route("/api/data")
@api_auth
def get_data():
    value, raw_mv = get_emg_value()
    ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    emg_history.append(value)
    csv_log.append({"timestamp": ts, "emg": value, "mv": raw_mv})
    il, ip = calc_intensity(value)
    fs, fp = calc_fatigue(emg_history)
    reps = update_reps(value)
    wp, rp, st, rf = update_wr(value)
    return jsonify({
        "timestamp": ts, "emg": value, "raw_mv": raw_mv, "history": list(emg_history),
        "intensity_label": il, "intensity_pct": ip, "fatigue_status": fs, "fatigue_pct": fp,
        "reps": reps, "work_pct": wp, "rest_pct": rp, "current_state": st, "ratio_flag": rf,
    })


@app.route("/api/status")
@api_auth
def status():
    u = session.get("user", "")
    return jsonify({
        "connected": connected,
        "port": SERIAL_PORT if connected else "SIMULATION",
        "mode": "Hardware" if connected else "Simulation",
        "user": u,
        "name": session.get("name", u),
        "email": session.get("email", ""),
    })


@app.route("/api/clear")
@api_auth
def clear_data():
    global rep_count, last_above, work_samples, rest_samples, current_state
    emg_history.clear()
    csv_log.clear()
    rep_count = 0
    last_above = False
    work_samples = 0
    rest_samples = 0
    current_state = "REST"
    return jsonify({"status": "cleared"})


@app.route("/api/download_csv")
@api_auth
def download_csv():
    if not csv_log:
        return "No data yet.", 400
    out = io.StringIO()
    w = csv.DictWriter(out, fieldnames=["timestamp", "emg", "mv"])
    w.writeheader()
    w.writerows(csv_log)
    return Response(
        out.getvalue(),
        mimetype="text/csv",
        headers={"Content-Disposition": f'attachment; filename=emg_{datetime.now().strftime("%Y%m%d_%H%M%S")}.csv'},
    )


@app.route("/api/save_session", methods=["POST"])
@api_auth
def save_session_data():
    # Session JSON dumps now go to stdout (CloudWatch picks them up).
    d = request.get_json() or {}
    payload = {**d, "user": session.get("user", "unknown"), "saved_at": datetime.now().isoformat()}
    print("SAVE_SESSION " + json.dumps(payload))
    return jsonify({"status": "saved"})


@app.route("/api/generate_report", methods=["POST"])
@api_auth
def generate_report():
    """Proxy to report-gen microservice."""
    if "csv_file" in request.files:
        f = request.files["csv_file"]
        content = f.read().decode("utf-8")
        rows = list(csv.DictReader(io.StringIO(content)))
        if not rows:
            return jsonify({"status": "error", "message": "CSV is empty"}), 400
        emg_vals = []
        for row in rows:
            try:
                emg_vals.append(float(row.get("emg", 0)))
            except ValueError:
                pass
        total = len(emg_vals)
        peak_p = int((max(emg_vals) / 4095) * 100) if emg_vals else 0
        avg_p = int((sum(emg_vals) / total / 4095) * 100) if total > 0 else 0
        above = False
        reps = 0
        for v in emg_vals:
            a = v > WORK_THRESHOLD
            if a and not above:
                reps += 1
            above = a
        if total > 40:
            half = total // 2
            fst = sum(emg_vals[:half]) / half
            snd = sum(emg_vals[half:]) / half
            drop = ((fst - snd) / fst * 100) if fst > 0 else 0
            fat = "Fatigued" if drop > 15 else "Mild Fatigue" if drop > 8 else "Normal"
        else:
            fat = "Normal"
        wc = sum(1 for v in emg_vals if v > WORK_THRESHOLD)
        wp = int((wc / total) * 100) if total > 0 else 0
        payload = {
            "reps": reps, "peak_pct": peak_p, "avg_pct": avg_p, "fatigue": fat,
            "work_pct": wp, "rest_pct": 100 - wp,
            "duration": f"{total // 10 // 60:02d}:{total // 10 % 60:02d}",
            "readings": total, "mode": "CSV Upload",
            "muscle": request.form.get("muscle", "Unknown"),
        }
    else:
        payload = request.get_json() or {}

    payload["user"] = session.get("user", "athlete")
    payload["name"] = session.get("name", payload["user"].capitalize())
    payload["email"] = session.get("email", "")

    try:
        r = requests.post(f"{REPORT_GEN_URL}/generate", json=payload, timeout=10)
        r.raise_for_status()
        return jsonify(r.json())
    except requests.RequestException as e:
        return jsonify({"status": "error", "message": f"Report service unavailable: {e}"}), 502


@app.route("/healthz")
def healthz():
    return {"status": "ok"}, 200


@app.route("/readyz")
def readyz():
    try:
        with engine.connect() as c:
            c.exec_driver_sql("SELECT 1")
        return {"status": "ready"}, 200
    except Exception as e:
        return {"status": "not_ready", "error": str(e)}, 503


if __name__ == "__main__":
    print("=" * 50)
    print("  MuscleQuant API")
    print(f"  DB:         {DB_URL.split('@')[-1] if '@' in DB_URL else DB_URL}")
    print(f"  Report-gen: {REPORT_GEN_URL}")
    print(f"  Mode:       {'HARDWARE' if connected else 'SIMULATION'}")
    print("=" * 50)
    init_db()
    app.run(host="0.0.0.0", port=8080, debug=False)
