#!/usr/bin/env bash
# Install / upgrade frwhoop-anomaly on the VPS (run as root from the unpacked release directory).
# Touches ONLY: user frwhoop-anom, /opt/frwhoop-anomaly, /opt/frwhoop-models/anomaly, /var/lib/frwhoop-anomaly,
# /etc/frwhoop/anomaly.env (created once, never overwritten), and the frwhoop-anomaly unit. It never restarts or
# edits frwhoop-worker / frwhoop-inference.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UV=/opt/uv/uv
[ -x "$UV" ] || UV="$(command -v uv)"
MODELS=/opt/frwhoop-models/anomaly

# Pinned upstream sources and weights (docs/BASELINE_WATCHDOG_V2.md §5; licenses recorded there).
TIMESFM_COMMIT=e51928e27119cb17bebc005be2696b75e0a9e688
TIMESFM_HF_REV=43046b85ec22d584a13f8098c2ed39c889e129c2
TIMESFM_SAFETENSORS_SHA=a7592b0a8432baee54483254e5647856911ce69e09d09a9bb65904b2d98f17da
TIMESFM_CONFIG_SHA=ff17bbc07b792c5a904cca265b8468579d736a4fe84981da25eb871b0a125bc6
UNITS_COMMIT=0e0281482864017cac8832b2651906ff5375a34e
UNITS_X128_SHA=35d17336c8857d2bacefe403fe7f21ec33ffae9f67d497d569e6af0cb38b5474

id frwhoop-anom >/dev/null 2>&1 || useradd --system --home /var/lib/frwhoop-anomaly --shell /usr/sbin/nologin frwhoop-anom
install -d -o frwhoop-anom -g frwhoop-anom -m 0750 /var/lib/frwhoop-anomaly
install -d -m 0755 /opt/frwhoop-anomaly "$MODELS"

sha_ok() { [ -f "$1" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]; }

# TimesFM source (Apache-2.0) at the pinned commit.
if [ ! -d "$MODELS/timesfm-src/.git" ] || [ "$(git -C "$MODELS/timesfm-src" rev-parse HEAD)" != "$TIMESFM_COMMIT" ]; then
  rm -rf "$MODELS/timesfm-src"
  git clone --quiet https://github.com/google-research/timesfm "$MODELS/timesfm-src"
  git -C "$MODELS/timesfm-src" checkout --quiet "$TIMESFM_COMMIT"
fi
# TimesFM 3.0 weights (TimesFM Non-Commercial License v1.0 — owner accepted; never redistributed off this host).
install -d "$MODELS/timesfm-3.0-pytorch"
for f in config.json model.safetensors LICENSE README.md; do
  want=""
  [ "$f" = model.safetensors ] && want=$TIMESFM_SAFETENSORS_SHA
  [ "$f" = config.json ] && want=$TIMESFM_CONFIG_SHA
  if [ -n "$want" ] && sha_ok "$MODELS/timesfm-3.0-pytorch/$f" "$want"; then continue; fi
  curl -fsSL -o "$MODELS/timesfm-3.0-pytorch/$f.part" \
    "https://huggingface.co/google/timesfm-3.0-pytorch/resolve/$TIMESFM_HF_REV/$f"
  mv "$MODELS/timesfm-3.0-pytorch/$f.part" "$MODELS/timesfm-3.0-pytorch/$f"
  if [ -n "$want" ] && ! sha_ok "$MODELS/timesfm-3.0-pytorch/$f" "$want"; then
    echo "sha256 mismatch for $f" >&2; exit 1
  fi
done
# UniTS source (MIT) and the x128 pretrain checkpoint (release tag ckpt).
if [ ! -d "$MODELS/units-src/.git" ] || [ "$(git -C "$MODELS/units-src" rev-parse HEAD)" != "$UNITS_COMMIT" ]; then
  rm -rf "$MODELS/units-src"
  git clone --quiet https://github.com/mims-harvard/UniTS "$MODELS/units-src"
  git -C "$MODELS/units-src" checkout --quiet "$UNITS_COMMIT"
fi
install -d "$MODELS/units-ckpt"
if ! sha_ok "$MODELS/units-ckpt/units_x128_pretrain_checkpoint.pth" "$UNITS_X128_SHA"; then
  curl -fsSL -o "$MODELS/units-ckpt/units_x128_pretrain_checkpoint.pth.part" \
    https://github.com/mims-harvard/UniTS/releases/download/ckpt/units_x128_pretrain_checkpoint.pth
  mv "$MODELS/units-ckpt/units_x128_pretrain_checkpoint.pth.part" "$MODELS/units-ckpt/units_x128_pretrain_checkpoint.pth"
  sha_ok "$MODELS/units-ckpt/units_x128_pretrain_checkpoint.pth" "$UNITS_X128_SHA" || { echo "UniTS sha256 mismatch" >&2; exit 1; }
fi
chmod -R a+rX "$MODELS"

# Code + venv (CPU torch wheel; Python 3.12).
rsync -a --delete --exclude .venv --exclude tests "$SRC_DIR/" /opt/frwhoop-anomaly/app/
if [ ! -x /opt/frwhoop-anomaly/venv/bin/python ]; then
  "$UV" venv --python /usr/bin/python3.12 /opt/frwhoop-anomaly/venv
fi
VIRTUAL_ENV=/opt/frwhoop-anomaly/venv "$UV" pip install --quiet \
  --index-url https://pypi.org/simple --extra-index-url https://download.pytorch.org/whl/cpu \
  torch==2.8.0 torchvision==0.23.0 numpy==2.2.6 safetensors==0.6.2 huggingface_hub==0.35.3 \
  "psycopg[binary]==3.2.10" timm==1.0.30 pyyaml==6.0.2
VIRTUAL_ENV=/opt/frwhoop-anomaly/venv "$UV" pip install --quiet --no-deps /opt/frwhoop-anomaly/app

# Env file: created once from the template; values are filled by the operator (never printed).
if [ ! -f /etc/frwhoop/anomaly.env ]; then
  install -m 0640 -o root -g frwhoop-anom "$SRC_DIR/deploy/anomaly.env.example" /etc/frwhoop/anomaly.env
  echo "created /etc/frwhoop/anomaly.env — fill FRWHOOP_ANOMALY_DB_URL before starting" >&2
fi

install -m 0644 "$SRC_DIR/deploy/frwhoop-anomaly.service" /etc/systemd/system/frwhoop-anomaly.service
systemd-analyze verify /etc/systemd/system/frwhoop-anomaly.service
systemctl daemon-reload
echo "installed; start with: systemctl enable --now frwhoop-anomaly"
