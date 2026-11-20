# Build stage: install dependencies into a venv we can copy across.
FROM python:3.14.10-slim-trixie AS build

RUN python -m venv /venv
COPY requirements.txt /tmp/requirements.txt
RUN /venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt


# Runtime stage: same base, no pip cache or build leftovers.
FROM python:3.14.10-slim-trixie

RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app

COPY --from=build /venv /venv
WORKDIR /app
COPY app.py .

ENV PATH="/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Numeric UID so Kubernetes runAsNonRoot can verify it.
USER 10001
EXPOSE 8080

# --preload: the app module (and its startup snapshot of the config files)
# is loaded once in the master, so a restarted worker keeps the same view.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "4", "--preload", "--access-logfile", "-", "app:app"]
