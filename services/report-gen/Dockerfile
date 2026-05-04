FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN groupadd -r app && useradd -r -g app -u 10001 app

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py ./

USER 10001
EXPOSE 8081
HEALTHCHECK --interval=20s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0) if urllib.request.urlopen('http://127.0.0.1:8081/healthz', timeout=2).status==200 else sys.exit(1)" || exit 1

CMD ["gunicorn", "--bind", "0.0.0.0:8081", "--workers", "2", "--threads", "4", "--access-logfile", "-", "app:app"]
