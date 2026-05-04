"""
MuscleQuant AI — report-gen microservice.
Stateless. Takes session metrics as JSON, returns a styled HTML report.
"""
from datetime import datetime

from flask import Flask, jsonify, request

app = Flask(__name__)

TIPS_MAP = {
    "Bicep": [
        "Focus on slow eccentric (lowering) phase to maximize time under tension",
        "Keep elbow fixed — avoid swinging to isolate bicep brachii",
        "Recommended: 3 sets of 8–12 reps at 70% 1RM for hypertrophy",
    ],
    "Tricep": [
        "Close-grip pressing targets all 3 tricep heads effectively",
        "Full extension at the bottom ensures complete muscle activation",
        "Recommended: Train triceps after chest day for best results",
    ],
    "Forearm": [
        "Wrist curls build both flexors and extensors equally",
        "Grip strength directly correlates with forearm EMG amplitude",
        "Recommended: High-rep training (15–20) with lighter loads",
    ],
    "Shoulder": [
        "Lateral raises should stay below shoulder height to protect rotator cuff",
        "Keep traps relaxed to isolate the deltoid during raises",
        "Recommended: Warm up rotator cuff before heavy pressing",
    ],
    "Chest": [
        "Wide grip targets pectorals; narrow grip shifts load to triceps",
        "Incline press recruits upper pec more than flat bench",
        "Recommended: Full range of motion is critical for peak activation",
    ],
    "Back": [
        "Drive elbows down and back — do not pull with biceps",
        "Scapular retraction before pulling is key for lat engagement",
        "Recommended: 2:1 pulling to pushing ratio for shoulder health",
    ],
    "Quad": [
        "Full depth squat recruits vastus medialis for knee stability",
        "Knee tracking over toes is critical to avoid joint stress",
        "Recommended: Compound lifts first, isolation last",
    ],
    "Glutes": [
        "Hip thrust has the highest glute EMG activation of any exercise",
        "Posterior pelvic tilt at the top ensures full contraction",
        "Recommended: Train glutes 2–3x per week for best hypertrophy",
    ],
    "Calf": [
        "Full range of motion — from full stretch to full plantar flexion",
        "Calves respond best to high frequency (4–5x per week)",
        "Recommended: Mix seated and standing to target both heads",
    ],
}

DEFAULT_TIPS = [
    "Maintain proper form throughout the movement",
    "Rest 48–72 hours between sessions for the same muscle group",
    "Progressive overload is the key driver of muscle growth",
]


def badge_html(label: str) -> str:
    good = ["Normal", "Good Balance", "Optimal", "Low Volume"]
    warn = ["Mild Fatigue", "Overworking", "Too Much Rest", "High"]
    bad = ["Fatigued"]
    if label in bad:
        c, bg = "#e74c3c", "#fdedec"
    elif label in warn:
        c, bg = "#f39c12", "#fef9e7"
    else:
        c, bg = "#27ae60", "#eafaf1"
    return f'<span style="background:{bg};color:{c};padding:3px 10px;border-radius:20px;font-size:12px;font-weight:600">{label}</span>'


def bar_html(pct: int, color: str) -> str:
    return (
        '<div style="display:flex;align-items:center;gap:10px">'
        '<div style="flex:1;height:6px;background:#f1f5f9;border-radius:3px;overflow:hidden">'
        f'<div style="width:{pct}%;height:100%;background:{color};border-radius:3px"></div></div>'
        f'<span style="font-size:12px;color:#94a3b8;width:32px">{pct}%</span></div>'
    )


def render_report(d: dict) -> str:
    muscle = str(d.get("muscle", "Unknown"))
    user = d.get("user", "athlete")
    name = str(d.get("name", user.capitalize()))
    reps = int(d.get("reps", 0))
    peak_pct = int(d.get("peak_pct", 0))
    avg_pct = int(d.get("avg_pct", 0))
    fatigue = str(d.get("fatigue", "Normal"))
    work_pct = int(d.get("work_pct", 0))
    rest_pct = int(d.get("rest_pct", 100))
    duration = str(d.get("duration", "00:00"))
    readings = int(d.get("readings", 0))
    mode = str(d.get("mode", "Live Session"))

    now = datetime.now()
    now_str = now.strftime("%B %d, %Y at %I:%M %p")
    date_str = now.strftime("%B %d, %Y")

    pk_col = "#e74c3c" if peak_pct > 75 else "#f39c12" if peak_pct > 50 else "#27ae60"
    av_col = "#e74c3c" if avg_pct > 75 else "#f39c12" if avg_pct > 50 else "#3498db"
    ft_col = "#e74c3c" if fatigue == "Fatigued" else "#f39c12" if "Mild" in fatigue else "#27ae60"
    wk_col = "#e74c3c" if work_pct > 80 else "#f39c12" if work_pct < 20 else "#27ae60"

    tips = TIPS_MAP.get(muscle, DEFAULT_TIPS)
    tip4 = (
        f"Allow 48 hours recovery before training {muscle} again."
        if fatigue != "Normal"
        else "Great recovery! Next session try increasing load by 5–10% for progressive overload."
    )

    rec_rows = ""
    for i, t in enumerate(tips):
        rec_rows += (
            '<div style="display:flex;gap:14px;align-items:flex-start;padding:14px 18px;'
            "background:#f8fafc;border-radius:10px;border-left:3px solid #3b82f6;margin-bottom:10px\">"
            '<div style="width:24px;height:24px;border-radius:50%;background:#3b82f6;color:white;'
            "display:flex;align-items:center;justify-content:center;font-size:11px;font-weight:700;flex-shrink:0\">"
            f"{i+1}</div>"
            f'<div style="font-size:14px;color:#334155;line-height:1.6">{t}</div></div>'
        )
    rec_rows += (
        '<div style="display:flex;gap:14px;align-items:flex-start;padding:14px 18px;'
        "background:#f8fafc;border-radius:10px;border-left:3px solid #f59e0b;margin-bottom:10px\">"
        '<div style="width:24px;height:24px;border-radius:50%;background:#f59e0b;color:white;'
        "display:flex;align-items:center;justify-content:center;font-size:11px;font-weight:700;flex-shrink:0\">4</div>"
        f'<div style="font-size:14px;color:#334155;line-height:1.6">{tip4}</div></div>'
    )

    fat_note = (
        "Your fatigue levels are within normal range — great work maintaining consistent output."
        if fatigue == "Normal"
        else "Mild fatigue detected. Consider increasing rest periods in your next session."
        if "Mild" in fatigue
        else "Significant fatigue detected. Prioritize recovery before your next session."
    )
    wr_note = (
        "Your work-to-rest ratio is well balanced."
        if 30 <= work_pct <= 70
        else "Consider adjusting your work-to-rest ratio for optimal muscle adaptation."
    )

    return (
        '<!DOCTYPE html><html lang="en"><head>'
        '<meta charset="UTF-8"/><meta name="viewport" content="width=device-width,initial-scale=1.0"/>'
        f"<title>MuscleQuant AI Report — {name}</title>"
        '<link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700;800&display=swap" rel="stylesheet"/>'
        "<style>"
        "*{margin:0;padding:0;box-sizing:border-box}"
        "body{font-family:Inter,sans-serif;background:#f8fafc;color:#1e293b}"
        "@media print{body{background:white}.no-print{display:none}.page{box-shadow:none;margin:0;border-radius:0}}"
        ".page{max-width:860px;margin:0 auto;background:white;box-shadow:0 4px 40px rgba(0,0,0,.08)}"
        ".header{background:linear-gradient(135deg,#0f172a 0%,#1e3a5f 60%,#0e7490 100%);padding:40px 48px 36px;color:white;position:relative;overflow:hidden}"
        '.header::before{content:"";position:absolute;right:-60px;top:-60px;width:280px;height:280px;border-radius:50%;background:rgba(255,255,255,.04)}'
        ".hdr-top{display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:28px;position:relative;z-index:1}"
        ".brand{display:flex;align-items:center;gap:14px}"
        ".brand-icon{width:48px;height:48px;border-radius:12px;background:linear-gradient(135deg,#22d3ee,#3b82f6);display:flex;align-items:center;justify-content:center;font-size:24px}"
        ".brand-name{font-size:22px;font-weight:800;letter-spacing:-.5px}"
        ".brand-name em{color:#22d3ee;font-style:normal}"
        ".brand-tag{font-size:11px;color:rgba(255,255,255,.5);letter-spacing:2px;text-transform:uppercase;margin-top:2px}"
        ".hdr-badge{background:rgba(34,211,238,.15);border:1px solid rgba(34,211,238,.3);color:#22d3ee;padding:6px 16px;border-radius:20px;font-size:12px;font-weight:600;letter-spacing:1px}"
        ".hdr-athlete{position:relative;z-index:1}"
        ".hdr-athlete h1{font-size:32px;font-weight:800;letter-spacing:-1px;margin-bottom:4px}"
        ".hdr-athlete h1 span{color:#22d3ee}"
        ".hdr-meta{display:flex;gap:16px;margin-top:10px;flex-wrap:wrap}"
        ".meta-pill{display:flex;align-items:center;gap:7px;background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.12);padding:5px 14px;border-radius:20px;font-size:12px;color:rgba(255,255,255,.8)}"
        ".stats-section{padding:32px 48px;background:#f8fafc;border-bottom:1px solid #e2e8f0}"
        ".stats-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:16px}"
        ".stat-card{background:white;border-radius:14px;padding:20px 22px;box-shadow:0 1px 8px rgba(0,0,0,.06);border:1px solid #e2e8f0;text-align:center}"
        ".stat-icon{font-size:26px;margin-bottom:8px}"
        ".stat-val{font-size:32px;font-weight:800;letter-spacing:-1px}"
        ".stat-lbl{font-size:11px;font-weight:600;color:#64748b;text-transform:uppercase;letter-spacing:1px;margin-top:4px}"
        ".section{padding:28px 48px;border-bottom:1px solid #f1f5f9}"
        ".section-title{font-size:13px;font-weight:700;color:#94a3b8;text-transform:uppercase;letter-spacing:2px;margin-bottom:18px}"
        ".metrics-table{width:100%;border-collapse:collapse}"
        ".metrics-table th{text-align:left;font-size:11px;font-weight:700;color:#94a3b8;text-transform:uppercase;letter-spacing:1px;padding:10px 14px;background:#f8fafc;border-bottom:2px solid #e2e8f0}"
        ".metrics-table td{padding:13px 14px;border-bottom:1px solid #f1f5f9;font-size:14px}"
        ".tech-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}"
        ".tech-item{background:#f8fafc;border-radius:10px;padding:14px 16px;border:1px solid #e2e8f0}"
        ".tech-label{font-size:10px;font-weight:700;color:#94a3b8;text-transform:uppercase;letter-spacing:1px;margin-bottom:4px}"
        ".tech-val{font-size:13px;font-weight:600;color:#1e293b}"
        ".footer{padding:24px 48px;background:#0f172a;color:rgba(255,255,255,.4);display:flex;justify-content:space-between;align-items:center}"
        ".footer-brand{font-size:13px;font-weight:700;color:rgba(255,255,255,.7)}"
        ".footer-brand em{color:#22d3ee;font-style:normal}"
        ".footer-note{font-size:11px}"
        ".print-btn{position:fixed;bottom:24px;right:24px;padding:12px 24px;background:linear-gradient(135deg,#22d3ee,#3b82f6);color:white;border:none;border-radius:10px;font-family:Inter,sans-serif;font-size:14px;font-weight:700;cursor:pointer;box-shadow:0 4px 20px rgba(59,130,246,.4)}"
        '</style></head><body><div class="page">'
        '<div class="header"><div class="hdr-top">'
        '<div class="brand"><div class="brand-icon">&#128170;</div>'
        '<div><div class="brand-name">Muscle<em>Quant</em> AI</div>'
        '<div class="brand-tag">Surface EMG Monitoring Report</div></div></div>'
        '<div class="hdr-badge">SESSION REPORT</div></div>'
        f'<div class="hdr-athlete"><h1>Hey, <span>{name}</span> &#128075;</h1>'
        '<p style="color:rgba(255,255,255,.6);font-size:14px;margin-top:4px">Here\'s your complete performance breakdown</p>'
        f'<div class="hdr-meta"><div class="meta-pill">&#128170; {muscle}</div>'
        f'<div class="meta-pill">&#128197; {date_str}</div>'
        f'<div class="meta-pill">&#9201; {now.strftime("%I:%M %p")}</div>'
        f'<div class="meta-pill">&#128202; {readings} data points</div>'
        "</div></div></div>"
        '<div class="stats-section"><div class="stats-grid">'
        f'<div class="stat-card"><div class="stat-icon">&#128260;</div><div class="stat-val" style="color:#0f172a">{reps}</div><div class="stat-lbl">Total Reps</div></div>'
        f'<div class="stat-card"><div class="stat-icon">&#9889;</div><div class="stat-val" style="color:{pk_col}">{peak_pct}%</div><div class="stat-lbl">Peak Intensity</div></div>'
        f'<div class="stat-card"><div class="stat-icon">&#9201;</div><div class="stat-val" style="color:#0f172a">{duration}</div><div class="stat-lbl">Duration</div></div>'
        "</div></div>"
        '<div class="section"><div class="section-title">Performance Metrics</div>'
        '<table class="metrics-table"><thead><tr><th>Metric</th><th>Value</th><th>Visual</th><th>Status</th></tr></thead><tbody>'
        f'<tr><td style="font-weight:600">Peak Intensity</td><td style="font-weight:700;font-size:16px;color:{pk_col}">{peak_pct}%</td><td>{bar_html(peak_pct, pk_col)}</td><td>{badge_html("High" if peak_pct > 75 else "Moderate" if peak_pct > 40 else "Low")}</td></tr>'
        f'<tr><td style="font-weight:600">Average Intensity</td><td style="font-weight:700;font-size:16px;color:{av_col}">{avg_pct}%</td><td>{bar_html(avg_pct, av_col)}</td><td>{badge_html("Optimal" if 30 <= avg_pct <= 70 else "Low" if avg_pct < 30 else "High")}</td></tr>'
        f'<tr><td style="font-weight:600">Fatigue Status</td><td style="font-weight:700;font-size:16px;color:{ft_col}">{fatigue}</td><td>—</td><td>{badge_html(fatigue)}</td></tr>'
        f'<tr><td style="font-weight:600">Work Time</td><td style="font-weight:700;font-size:16px;color:{wk_col}">{work_pct}%</td><td>{bar_html(work_pct, wk_col)}</td><td>{badge_html("Good Balance" if 30 <= work_pct <= 70 else "Overworking" if work_pct > 70 else "Too Much Rest")}</td></tr>'
        f'<tr><td style="font-weight:600">Rest Time</td><td style="font-weight:700;font-size:16px">{rest_pct}%</td><td>{bar_html(rest_pct, "#64748b")}</td><td>{badge_html("Normal")}</td></tr>'
        "</tbody></table></div>"
        f'<div class="section"><div class="section-title">&#128170; {muscle} Analysis</div>'
        '<div style="background:#f0fdf4;border:1px solid #bbf7d0;border-radius:12px;padding:18px 22px">'
        f'<p style="font-size:14px;line-height:1.7;color:#166534"><strong>{name}</strong>, your {muscle} session showed a peak activation of <strong>{peak_pct}%</strong> with an average of <strong>{avg_pct}%</strong> across {readings} data points over {duration}. {fat_note} {wr_note}</p></div></div>'
        f'<div class="section"><div class="section-title">Recommendations</div>{rec_rows}</div>'
        '<div class="section"><div class="section-title">Technical Information</div><div class="tech-grid">'
        '<div class="tech-item"><div class="tech-label">Sensor</div><div class="tech-val">MyoWare 2.0</div></div>'
        '<div class="tech-item"><div class="tech-label">Microcontroller</div><div class="tech-val">ESP32</div></div>'
        '<div class="tech-item"><div class="tech-label">Baud Rate</div><div class="tech-val">115200</div></div>'
        '<div class="tech-item"><div class="tech-label">ADC Resolution</div><div class="tech-val">12-bit (0–4095)</div></div>'
        '<div class="tech-item"><div class="tech-label">Sample Rate</div><div class="tech-val">10 Hz</div></div>'
        f'<div class="tech-item"><div class="tech-label">Data Source</div><div class="tech-val">{mode}</div></div>'
        "</div></div>"
        '<div class="footer"><div class="footer-brand">Muscle<em>Quant</em> AI &mdash; Surface EMG Monitoring</div>'
        f'<div class="footer-note">Generated {now_str} &middot; Confidential</div></div></div>'
        '<button class="print-btn no-print" onclick="window.print()">&#128438; Print / Save PDF</button>'
        "</body></html>"
    )


@app.route("/generate", methods=["POST"])
def generate():
    payload = request.get_json(silent=True) or {}
    return jsonify({"status": "ok", "html": render_report(payload)})


@app.route("/healthz")
def healthz():
    return {"status": "ok"}, 200


@app.route("/readyz")
def readyz():
    return {"status": "ready"}, 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8081, debug=False)
