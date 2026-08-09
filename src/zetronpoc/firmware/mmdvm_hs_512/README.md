# MMDVM_HS — Firmware 512 baud POCSAG (flag `POCSAG_512`)

Fork de trabajo del firmware **MMDVM_HS** (juribeparada/MMDVM_HS) con un flag de
build `POCSAG_512` que reconfigura el **registro R3 (Clock Register) del ADF7021**
para que el Jumbospot transmita POCSAG a **512 baud** en lugar de 1200, sin tocar
el hardware. Con esto los pagers de 512 decodifican el texto en vez del chorizo
"number-hyphen" actual.

> ⚠️ **Esto es firmware. Compilar y flashear lo hacés vos en el Jumbospot.** Acá
> están los parches, la calculadora de registros y los pasos de build/flash.

---

## Por qué solo cambia R3 (y no REG4 / REG10)

El PRD original mencionaba recalcular REG3, REG4 y REG10. Revisando el datasheet
del ADF7021 y la estructura del firmware:

| Registro | Función | ¿Afecta la TX POCSAG? |
|---|---|---|
| **R3** (Clock) | `DEMOD_CLK`, `CDR_CLK` → fija el **baud de TX** | **SÍ** ← este cambia |
| R2 (Modulación) | Desviación FSK (`ADF7021_DEV_POCSAG=160` ≈ ±4.5 kHz) | No: ±4.5 kHz es estándar POCSAG para 512 y 1200 |
| R4 (Demod) | Discriminator BW + post-demod BW | **No**: es path de **RX**. El Jumbospot acá es **TX-only** |
| R10 (AFC) | Automatic Frequency Control | **No**: es path de **RX** |

El baud físico de transmisión lo fija el ADF7021 a partir de `CDR_CLK / 32`, y
`CDR_CLK = XTAL / (DEMOD_CLK_DIVIDE × CDR_CLK_DIVIDE)`. Cambiar solo R3 es el
cambio mínimo y de menor riesgo: no tocamos desviación ni filtros RX, así el
fallback a 1200 es limpio y no hay chance de over-deviation ni de corromper RX.

---

## Valores calculados (datasheet ADF7021, Register 3)

Fórmulas del datasheet:
```
DEMOD_CLK = XTAL / DEMOD_CLK_DIVIDE          (R3 bits DB9:DB6, 4 bits, 1..15)
CDR_CLK   = DEMOD_CLK / CDR_CLK_DIVIDE        (R3 bits DB17:DB10, 8 bits, 1..255)
CDR_CLK ≈ 32 × baud   (dentro de 2%)
Restricciones: 2 MHz ≤ DEMOD_CLK ≤ XTAL ;  CDR_CLK_DIVIDE ≤ 255
```

### Variante 14.7456 MHz (ZumSpot / Jumbospot actuales) — `ADF7021_14_7456`
XTAL = 14.7456 MHz, PFD = 3.6864 MHz.

| | DEMOD_CLK_DIVIDE | CDR_CLK_DIVIDE | DEMOD_CLK | CDR_CLK | baud |
|---|---|---|---|---|---|
| 1200 (default) | 2 | 192 | 7.3728 MHz | 38400 Hz | 32×1200 |
| **512** | **4** | **225** | 3.6864 MHz | 16384 Hz | **32×512 (exacto)** |

```
R3 1200 = 0x2A4F0093   →   R3 512 = 0x2A4F8513
```

### Variante 12.2880 MHz (placas viejas) — `ADF7021_12_2880`
XTAL = 12.288 MHz, PFD = 6.144 MHz.

| | DEMOD_CLK_DIVIDE | CDR_CLK_DIVIDE | DEMOD_CLK | CDR_CLK | baud |
|---|---|---|---|---|---|
| 1200 (default) | 2 | 160 | 6.144 MHz | 38400 Hz | 32×1200 |
| **512** | **3** | **250** | 4.096 MHz | 16384 Hz | **32×512 (exacto)** |

```
R3 1200 = 0x29EE8093   →   R3 512 = 0x29EFE8D3
```

> Si tu TCXO es otro (ej. 6.144 MHz standalone), corré `tools/reg3_calc.py`
> con tu `ADF7021_REG3_POCSAG` de 1200 y el XTAL real — te calcula el R3 de 512.

---

## Suposición a VERIFICAR antes de flashear

**Asumo TCXO 14.7456 MHz** (variante ZumSpot/Jumbospot más común → define
`ADF7021_14_7456`). Antes de compilar confirmá cuál de los dos bloques usa tu
placa mirando tu `platformio.ini` / `Config.h`:
- `ADF7021_14_7456` → usá el valor `0x2A4F8513`.
- `ADF7021_12_2880` → usá el valor `0x29EFE8D3` (ese bloque ya está en el parche).

Si usás el set de registros del TCXO equivocado **el TX no funciona o transmite
fuera de banda**. Verificá primero.

---

## Build + flash (resumen)

```bash
# 1) Clonar el MMDVM_HS oficial y aplicar el parche del flag
cd src/zetronpoc/firmware/mmdvm_hs_512
./clone_and_patch.sh            # clona juribeparada/MMDVM_HS y aplica patches/ADF7021.h.patch

# 2) Compilar el env de tu placa con el flag POCSAG_512
cd MMDVM_HS
pio run -e pocsag512-144         # ver platformio.ini (ajustá el env a tu board)

# 3) Flashear el STM32 del Jumbospot por USB (modo DFU)
./../flash.sh .pio/build/pocsag512-144/firmware.bin

# 4) Reiniciar el servicio y probar
sudo systemctl restart mmdvmhost
# Disparar un page de prueba desde el panel admin (Diagnóstico -> Test page)
# El pager de 512 debe recibir el texto legible.
```

Detalle de cada paso en las secciones siguientes.

---

## 1) Aplicar el parche (flag `POCSAG_512`)

`clone_and_patch.sh` hace:
1. `git clone https://github.com/juribeparada/MMDVM_HS`
2. `git apply patches/ADF7021.h.patch` (con fallback `--3way`)

El parche (`patches/ADF7021.h.patch`) reemplaza, en **ambos** bloques de TCXO,
el `#define ADF7021_REG3_POCSAG` por un bloque `#if defined(POCSAG_512) / #else`:

```cpp
#if defined(POCSAG_512)
// 512 baud: DEMOD_CLK_DIVIDE=4, CDR_CLK_DIVIDE=225 -> CDR_CLK=16384=32x512
#define ADF7021_REG3_POCSAG      0x2A4F8513
#else
// 1200 baud (default): DEMOD_CLK_DIVIDE=2, CDR_CLK_DIVIDE=192 -> 38400=32x1200
#define ADF7021_REG3_POCSAG      0x2A4F0093
#endif
```

Sin definir `POCSAG_512` → compila el 1200 original (fallback reversible limpio).

---

## 2) Compilar

Requisitos: [PlatformIO Core](https://platformio.org/) (`pip install platformio`)
+ toolchain `arm-none-eabi-gcc` (PIO lo baja solo).

Definir el flag en el env elegido (ver `platformio.ini`). El flag **siempre** debe
ir junto al define de TCXO correcto (`-DADF7021_14_7456` o `-DADF7021_12_2880`):

```ini
[env:pocsag512-144]
build_flags =
  ${env.build_flags}
  -DADF7021_14_7456
  -DPOCSAG_512
```

```bash
pio run -e pocsag512-144
```

El binario queda en `.pio/build/pocsag512-144/firmware.bin`.

---

## 3) Flashear el Jumbospot (STM32, USB-DFU)

1. Desconectá el Jumbospot del USB.
2. Pone el STM32 en modo DFU: puente `BOOT0=1` (o botón de boot si lo tiene) y
   reconectá al USB.
3. Verificá: `lsusb` → aparece `STMicroelectronics STM Device in DFU Mode`.
4. Flasheá:

```bash
./flash.sh .pio/build/pocsag512-144/firmware.bin
# equivalente a: dfu-util -a 0 -s 0x08008000:leave -D firmware.bin
```

5. Sacá el puente `BOOT0`, desconectá/reconectá USB → arranca con el nuevo fw.

> `flash.sh` usa `dfu-util`. Instalá con `sudo apt install dfu-util`.

---

## 4) Verificar

```bash
# Servicio activo
sudo systemctl restart mmdvmhost
journalctl -u mmdvmhost -f | grep -i pocsag
```

Desde el panel admin (Diagnóstico → Test page) dispará un page a un cap de 512.
El pager debe mostrar el **texto legible**. Si llega el chorizo number-hyphen,
el flag no quedó compilado o el env usó el TCXO equivocado — revisá el build.

---

## Fallback reversible a 1200

Si 512 no decodifica o la TX se corrompe:
1. Recompilar **sin** `-DPOCSAG_512` (el `#else` del parche restaura 0x2A4F0093).
2. Re-flashear.
3. No hace falta tocar `MMDVM.ini` ni el pipeline `dispatch_mqtt`.

---

## Archivos

| Archivo | Qué hace |
|---|---|
| `patches/ADF7021.h.patch` | diff que agrega el `#if POCSAG_512` en R3 (14.7456 y 12.2880) |
| `tools/reg3_calc.py` | Calcula R3 para cualquier baud/XTAL desde el baseline de 1200 |
| `clone_and_patch.sh` | Clona MMDVM_HS oficial y aplica el parche |
| `platformio.ini` | Ejemplo de env de build con `-DPOCSAG_512` (ajustá el board) |
| `flash.sh` | Flashea el .bin al STM32 con dfu-util |

---

## Recalculo manual / otro baud

```bash
python3 tools/reg3_calc.py 0x2A4F0093 14745600 512
# Baseline R3 = 0x2A4F0093
#   DEMOD_CLK_DIVIDE = 2  -> DEMOD_CLK = 7372800 Hz
#   CDR_CLK_DIVIDE   = 192 -> CDR_CLK = 38400 Hz  baud = 1200
# Target 512 baud:
#   DEMOD_CLK_DIVIDE = 4  -> DEMOD_CLK = 3686400 Hz
#   CDR_CLK_DIVIDE   = 225 -> CDR_CLK = 16384 Hz  (32x512=16384)  err=0.000%
#   NUEVO R3 = 0x2A4F8513
```

Para 12.2880: `python3 tools/reg3_calc.py 0x29EE8093 12288000 512` → `0x29EFE8D3`.