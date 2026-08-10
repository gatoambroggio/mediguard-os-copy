# MMDVM_HS — Firmware 512 baud POCSAG (flag `POCSAG_512`)

Fork de trabajo del firmware **MMDVM_HS** (juribeparada/MMDVM_HS) para que el
Jumbospot transmita POCSAG a **512 baud** y los pagers de 512 decodifiquen
texto legible en vez del chorizo "number-hyphen" actual.

> ⚠️ **Esto es firmware. Compilar y flashear lo hacés vos en el Jumbospot.** El
> `.bin` precompilado lo entrega un workflow de GitHub Actions (ver más abajo);
> vos lo flasheas con `flash.sh`.

---

## El diagnóstico (probado, no adivinado)

El MMDVM_HS oficial **solo soporta POCSAG a 1200 baud** (dice el repo: *"POCSAG
1200 pager protocol"*). El baud de TX lo fija el **STM32**, no el ADF7021:

| Palanca | Qué hace | ¿Cambia el baud de TX? |
|---|---|---|
| **STM32 `CIO::interrupt()`** | ISR del timer que drena `m_txBuffer` al pin **TXD** del ADF7021 | **SÍ** ← esta hay que tocar |
| R3 `ADF7021_REG3_POCSAG` | `CDR_CLK` = clock de **recuperación de RX** | **NO** (RX-only) |
| `POCSAG_512` en `Config.h` | no se lee para el baud | **NO** |
| `packNumeric` / `BCD_VALUES` (MMDVMHost) | cifrado del mensaje | **NO** (probado: nibble 0 perfecto) |

**Por qué tus dos intentos anteriores no anduvieron (dead-ends confirmados):**
- `POCSAG_512` en `Config.h` → el baud no se lee de ahí.
- R3 `0x2A4F8513` en `ADF7021.h` → R3 fija `CDR_CLK` (RX), no el TX.

Los dos palazos fueron al ADF7021. El baud real lo da el **timer del STM32** (la
ISR `CIO::interrupt()` que clockea `TXD`). El `createCal` del código genera un
*"600 Hz square wave"* = el tono de preamble de **1200 baud**, confirmando el
default. Ese timer **nunca fue parcheado**. Es el palo que falta.

**La prueba definitiva de que NO es bit-level:** un mensaje `00000` (puros ceros)
no puede dar dígitos no-cero si el pager leyera el campo de mensaje — los
dígitos que ves (`0381 06030`) salen de leer paridad BCH / IDLE como mensaje, que
es justo lo que pasa cuando el baud no coincide y el pager pierde el encuadre.

---

## El flujo (find → confirm → patch → build → flash)

### 1) Clonar y localizar el bit-clock
```bash
cd src/zetronpoc/firmware/mmdvm_hs_512
./clone_and_patch.sh
```
Esto clona `juribeparada/MMDVM_HS`, aplica el parche de R3 (queda por consistencia,
pero **no es el que resuelve el baud**), y corre `tools/find_pocsag_clock.py`,
que imprime el **POCSAG BIT-CLOCK REPORT**: la ISR `CIO::interrupt()`, el setup
del timer `CIO::startInt()`, el branch `STATE_POCSAG` de `ifConf()`, y las
constantes candidatas a samples-per-bit — todo con números de línea.

### 2) Confirmar el lever
Del reporte identificás:
- la **línea** que fija el samples-per-bit de POCSAG (o el divider del timer
  para `STATE_POCSAG`), y
- la **base rate** del timer (sample rate en `startInt()`).

Con esos dos datos, el patch a 512 baud es:
```
new_samples_per_bit = round(base_rate / 512)
```
- Si base = **24 kHz** → 47 muestras/bit → 510.6 baud (0.27% err, dentro 2%).
- Si base = **9.6 kHz** → 19 muestras/bit → 505.3 baud (1.37% err, dentro 2%).

### 3) Aplicar el patch (envuelto en `#if defined(POCSAG_512) / #else`)
La línea confirmada se reemplaza por un bloque reversible:
```cpp
#if defined(POCSAG_512)
// 512 baud: round(base_rate/512) muestras/bit
<samples_per_bit = NEW>
#else
// 1200 baud (default MMDVM_HS)
<samples_per_bit = OLD>
#endif
```
Sin `-DPOCSAG_512` → compila el 1200 original (fallback limpio).

### 4) Compilar
```bash
./build_firmware.sh
# -> firmware_pocsag512.bin
```
Requisitos: PlatformIO Core (`pip install platformio`) + toolchain ARM (PIO lo
baja solo). El flag crítico `-DPOCSAG_512` ya está en el env `pocsag512-144`
del `platformio.ini`, junto a `-DADF7021_14_7456` (TCXO 14.7456 MHz,
Jumbospot/ZumSpot).

### 5) Flashear el Jumbospot (STM32, USB-DFU)
1. Desconectá el Jumbospot del USB.
2. Poné el STM32 en modo DFU: puente `BOOT0=1` y reconectá al USB.
3. `lsusb` → aparece `STMicroelectronics STM Device in DFU Mode`.
4. Flasheá:
   ```bash
   ./flash.sh firmware_pocsag512.bin
   # equivale a: dfu-util -a 0 -s 0x08008000:leave -D firmware_pocsag512.bin
   ```
5. Sacá el puente `BOOT0`, desconectá/reconectá USB → arranca con el nuevo fw.

> `flash.sh` usa `dfu-util` (`sudo apt install dfu-util`).

### 6) Verificar
```bash
sudo systemctl restart mmdvmhost
journalctl -u mmdvmhost -f | grep -i pocsag
```
Desde el panel admin (Diagnóstico → Test page) dispará un page a un cap de 512.
El pager debe mostrar **texto legible**.

---

## `.bin` precompilado (sin instalar PlatformIO)

No tenés toolchain ARM a mano: el `.bin` lo compila un **workflow de GitHub
Actions** al publicar el source al repo. El workflow corre `clone_and_patch.sh`
+ `build_firmware.sh` y publica `firmware_pocsag512.bin` como **Release**
descargable. URL de descarga directa una vez publicado:
```
https://github.com/<owner>/<repo>/releases/download/pocsag512-latest/firmware_pocsag512.bin
```

> El workflow solo publica el `.bin` cuando el patch a 512 baud quedó aplicado.
> Si `find_pocsag_clock.py` no encuentra el lever (detección ambigua), el
> workflow **falla ruidosamente** con el reporte en el log — no publica un
> `.bin` a 1200 baud trancado como si fuera 512.

---

## Fallback reversible a 1200

Si 512 no decodifica o la TX se corrompe:
1. Recompilar **sin** `-DPOCSAG_512` (el `#else` restaura el samples-per-bit de 1200).
2. Re-flashear.
3. No hace falta tocar `MMDVM.ini` ni el pipeline `dispatch_mqtt`.

---

## Archivos

| Archivo | Qué hace |
|---|---|
| `patches/ADF7021.h.patch` | diff de R3 con `#if POCSAG_512` (RX-only, queda por consistencia) |
| `tools/find_pocsag_clock.py` | **Localiza el bit-clock real de POCSAG** en el source clonado (reporte con líneas) |
| `tools/reg3_calc.py` | Recalcula R3 para cualquier baud/XTAL (referencia, no resuelve el TX) |
| `clone_and_patch.sh` | Clona MMDVM_HS oficial, aplica patches y corre el finder |
| `build_firmware.sh` | Compila el env `pocsag512-144` y copia el `.bin` al fork |
| `platformio.ini` | Env de build con `-DPOCSAG_512 -DADF7021_14_7456` |
| `flash.sh` | Flashea el `.bin` al STM32 con `dfu-util` |

---

## TCXO

Este fork asume **TCXO 14.7456 MHz** (Jumbospot/ZumSpot actuales → define
`ADF7021_14_7456`). Si tu placa es 12.2880 MHz, usá el env `pocsag512-122880`
(comentado en `platformio.ini`) con `-DADF7021_12_2880`. Verificá tu TCXO antes de
compilar; usar el set de registros equivocado hace que la TX no funcione o salga
fuera de banda.