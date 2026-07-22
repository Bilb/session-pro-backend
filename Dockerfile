# Session Pro backend container image.
#
# The app builds its Flask WSGI object at import time (`flask_app = entry_point()`
# in main.py), so it is served by a WSGI server (uwsgi, pinned in requirements.txt).
# Config is via SESH_PRO_BACKEND_* env vars and/or an .ini file (see docker-compose.yml).
# The SQLite DB under /data holds the backend signing key AND all Pro subscriptions,
# so mount a volume there to persist both across restarts/rebuilds.
#
# Base is debian bookworm (NOT python:3.x): the backend needs libsession-util's Python
# bindings (`session_util`), and the Oxen apt repo ships them PREBUILT as
# `python3-session-util` for the distro's Python (3.11 on bookworm). Building the bindings
# from source against the repo's libsession-util fails on a ustring_view version mismatch,
# so we use the prebuilt package and run under the matching system Python.
FROM debian:bookworm-slim
     
ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app

# Oxen apt repo -> prebuilt `python3-session-util` (pulls libsession-util as a dep).
# build-essential + python3-dev are only needed to compile uwsgi from requirements.txt.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && curl -fsSo /etc/apt/trusted.gpg.d/oxen.gpg https://deb.oxen.io/pub.gpg \
 && echo "deb https://deb.oxen.io bookworm main" > /etc/apt/sources.list.d/oxen.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-venv python3-dev build-essential python3-session-util \
 && rm -rf /var/lib/apt/lists/*

# Virtualenv WITH access to system site-packages so the apt-provided `session_util`
# module is importable while pip-installed deps live in the venv.
RUN python3 -m venv --system-site-packages /venv
ENV PATH="/venv/bin:$PATH"

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# The DB (and therefore the signing key + subscriptions) lives here. Mount a volume.
ENV SESH_PRO_BACKEND_DB_URL=sqlite:////data/pro.db
RUN mkdir -p /data
VOLUME ["/data"]

EXPOSE 5000

# One process, threads enabled, app imported AFTER fork (--lazy-apps) so the backend's
# maintenance thread (started at import) runs inside the worker rather than the master.
CMD ["uwsgi", "--http", ":5000", \
     "--module", "main:flask_app", \
     "--master", "--processes", "1", \
     "--enable-threads", "--lazy-apps", \
     "--http-timeout", "120"]
