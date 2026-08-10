#!/usr/bin/env bash
# verify_baud.sh - Verifica el baud real de TX POCSAG del Jumbospot flasheado.
#
# Mide el tono del preamble POCSAG (alternancia 10101...):
#   600 Hz -> 1200 baud (el flag -DPOCSAG_512 NO tomo efecto)
#   256 Hz -> 512 baud  (OK, el pager de 512 deberia decodificar limpio)
#
# Metodo: dispara un page de prueba (preamble largo) y muestrea la portadora
# con rtl_fm + sox, despues FFT en Python para hallar el tono dominante
# en 200-700 Hz.
#
# Requiere: rtl-sdr (rtl_fm), sox, python3+numpy.
#   sudo apt install rtl-sdr sox python3-numpy
#
# Uso:
#   ./verify_baud.sh <frecuencia_hz> [cap_code]
#   ./verify_baud.sh 145000000 1234567
set -euo pipefail

FREQ="${1:?Uso: verify_baud.sh <frecuencia_hz> [cap_code]}"
CAP="${2:-1234567}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WAV="/tmp/pocsag_verify.wav"
DUR=6  # segundos de captura

for cmd in rtl_fm sox python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: falta '$cmd'.  sudo apt install rtl-sdr sox python3-numpy"
    exit 2
  fi
done

echo "[1/3] Capturando ${DUR}s a ${FREQ} Hz (disparando page de prueba en cap ${CAP})..."
# Lanzamos el page en background para tener preamble durante la captura.
( sleep 1; /opt/zetronpoc/agi/dispatch_mqtt.py --bcd "$CAP" "10000" >/dev/null 2>&1 || true ) &
PAGE_PID=$!

# rtl_fm -> 48 kHz WAV. El tono POCSAG (256/600 Hz) queda en la envolvente
# de la portadora demodulada; bajamos el sample rate para verlo.
rtl_fm -f "$FREQ" -s 48k -g 40 -l 0 - 2>/dev/null | \
  sox -t raw -r 48k -e signed -b 16 -c 1 - "$WAV" trim 0 "$DUR" 2>/dev/null || true

wait "$PAGE_PID" 2>/dev/null || true

if [ ! -s "$WAV" ]; then
  echo "ERROR: no se capturo audio. ¿RTL-SDR conectado? ¿Frecuencia correcta?"
  exit 3
fi

echo "[2/3] FFT para hallar el tono del preamble..."
python3 - "$WAV" <<'PY'
import sys, wave, struct
import numpy as np

w = wave.open(sys.argv[1], "rb")
fs = w.getframerate()
n = w.getnframes()
raw = w.readframes(n)
w.close()
x = np.frombuffer(raw, dtype=np.int16).astype(np.float32)

# El tono POCSAG aparece como modulacion FSK 2-nivel sobre la portadora.
# Demodulamos FM (diferencia de fase) y buscamos el dominante en 200-700 Hz.
# Simplificacion: derivada del nivel -> realce del tono de bit.
if len(x) < 4096:
    print("ERROR: captura muy corta"); sys.exit(1)

# Hilbert envolvente aproximada: magnitud de señal menos su media movil.
# Trabajamos con el espectro directo en la banda de interes.
x -= x.mean()
win = 8192
hop = win // 2
# Promediamos espectros de varias ventanas para estabilizar.
freqs = np.fft.rfftfreq(win, 1.0/fs)
band = (freqs >= 80) & (freqs <= 1500)   # bajamos el piso: el tono de bit
                                          # aparece como energia periodica.
psd = np.zeros(len(freqs))
nseg = 0
i = 0
while i + win <= len(x):
    seg = x[i:i+win] * np.hanning(win)
    sp = np.abs(np.fft.rfft(seg))**2
    psd += sp
    nseg += 1
    i += hop
if nseg == 0:
    print("ERROR: captura muy corta"); sys.exit(1)
psd /= nseg

# Pero el tono POCSAG esta en la desviacion FSK, no en la portadora base.
# Mejor: detectar transiciones. Contamos cruces por cero de la envolvente
# demodulada como proxy de la frecuencia de bit.
# Demodulacion FM burda: angulo de la señal analitica.
from numpy import angle, unwrap, diff
analytic = x  # simplificacion
# Usamos la diferencia de la señal como detector de FSK burdo:
d = np.diff(x)
z = np.abs(d)
z -= z.mean()
# FFT de la envolvente del detector:
zp = np.zeros(len(freqs))
i = 0
while i + win <= len(z):
    seg = z[i:i+win] * np.hanning(win)
    zp += np.abs(np.fft.rfft(seg))**2
    i += hop
zp /= max(nseg,1)

idx = np.argmax(zp[band])
tone = freqs[band][idx]
# Si no emerge un tono claro, caemos al PSD de la señal directa.
if tone < 50:
    idx = np.argmax(psd[band])
    tone = freqs[band][idx]

print("Tono dominante detectado: %.1f Hz" % tone)
if abs(tone - 256) < 40:
    print("  => ~256 Hz = 512 baud. El flag -DPOCSAG_512 funciono. El pager de 512 deberia decodificar limpio.")
elif abs(tone - 600) < 60:
    print("  => ~600 Hz = 1200 baud. El flag -DPOCSAG_512 NO tomo efecto (revisar build/flash).")
else:
    print("  => Tono no concluyente (%.1f Hz). Revisar antena/ganancia/frecuencia o volver a capturar." % tone)
PY

echo "[3/3] Listo. Captura temporal en ${WAV}"