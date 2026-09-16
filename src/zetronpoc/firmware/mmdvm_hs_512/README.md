# MMDVM_HS — Firmware 512 baud POCSAG + 149.255 MHz (Nano_hotSPOT)

Firmware **MMDVM_HS** customizado para el sistema **MediGuard OS** (paginación
hospitalaria de emergencia). Dos fixes sobre el firmware oficial:

1. **149.255 MHz**: extendido `VHF1_MAX` de 148 a 150 MHz en `IO.h` para que el
   firmware acepte la frecuencia sin NAK reason 4 y seleccione `REG1_VHF1` (VCO
   externo, correcto para VHF) en `ifConf()`.

2. **512 baud POCSAG**: reconfigurado `REG3` del ADF7021 (`ADF7021.h`) para que el
   CLK output del ADF7021 genere 512 baud en lugar de 1200. **El baud de TX lo
   controla el ADF7021**, no un timer del STM32.

> ⚠️ **Esto es firmware. Compilar y flashear lo hacés vos en el Jumbospot.** El
> `.bin` precompilado lo entrega un workflow de GitHub Actions; vos lo flasheas
> con `flash.sh`.

---

## El diagnóstico (probado en el source, no adivinado)

### 1. El baud de TX lo controla el ADF7021, NO el STM32

El `interrupt()` del MMDVM_HS **es disparado por el CLK output del ADF7021** (no
por un timer del STM32):

```cpp
// ADF7021.cpp — void CIO::interrupt()
uint8_t clk = CLK_pin();           // ← CLK del ADF7021
if (clk == last_clk) return;       // fire on edge
else last_clk = clk;

if (m_tx && clk == 0U) {           // falling edge → TX
    m_txBuffer.get(bit, m_control);
    TXD_pin(bit ? HIGH : LOW);     // 1 bit por flanco de bajada
}
if (!m_tx && clk == 1U) {          // rising edge → RX
    m_rxBuffer.put(RXD_pin(), ...);
}
```

El CLK output del ADF7021 se configura con el **registro REG3**. Por lo tanto,
**cambiar REG3 cambia el baud de TX** (y RX). El README anterior que decía "R3 es
RX-only" estaba equivocado.

### 2. 149.255 MHz cae fuera del rango VHF1 (144-148 MHz)

En `IO.h`:
```cpp
#define VHF1_MIN  144000000
#define VHF1_MAX  148000000   // ← 149.255 MHz queda FUERA
```

Esto causa dos problemas en `IO.cpp` + `ADF7021.cpp`:

| Función | Qué pasa con 149.255 MHz | Consecuencia |
|---|---|---|
| `setFreq()` | No cae en ninguna banda válida → **NAK reason 4** | MMDVMHost no puede setear la freq |
| `ifConf()` | Cae al `else` → usa `REG1_UHF1` (VCO interno UHF) | PLL no lockea → **no hay RF** |

**El fix**: extender `VHF1_MAX` a 150 MHz. El ADF7021 con VCO externo (`REG1_VHF1`)
soporta 80-325 MHz, así que 149.255 MHz es físicamente alcanzable.

---

## ⚠️ Fix crítico: DUPLEX removido (v2)

El primer build tenía `#define DUPLEX` en Config.h, pero el Nano hotSPOT tiene
**un solo ADF7021** (es simplex). Con DUPLEX activado, el firmware configura un
EXTI interrupt en PA5 para un segundo ADF7021 que no existe en la placa. Si PA5
está flotando, el STM32 se queda trabado atendiendo interrupciones espurias y
**nunca responde al UART** — MMDVMHost no puede obtener la versión del firmware.

**Fix**: `DUPLEX` removido de Config.h. La placa ahora compila como simplex
(single ADF7021), que es lo correcto para el Nano hotSPOT / Jumbospot.

---

## Los 3 patches

| # | Archivo | Qué hace |
|---|---|---|
| 1 | `patches/Config.h` | Reemplazo completo: `NANO_HOTSPOT`, **SIMPLEX (sin DUPLEX)**, `STM32_USART1_HOST`, `ADF7021_14_7456` |
| 2 | `patches/IO.h.patch` | `VHF1_MAX`: 148000000 → 150000000 (envuelto en `#if defined(POCSAG_149MHZ)`) |
| 3 | `patches/ADF7021.h.patch` | `ADF7021_REG3_POCSAG`: 512 baud (envuelto en `#if defined(POCSAG_512)`) |

---

## Build flow (local o GitHub Actions)

### Opción A: GitHub Actions (automático)

El workflow vive en `workflow-template.yml` dentro de este directorio. Al
publicar desde el panel admin (Descarga → "Publicar a GitHub"), el publicador
lo remapea a `.github/workflows/build-firmware.yml` en la raiz del repo.

> **Requisito**: el conector de GitHub debe tener el scope `workflow` (además de
> `repo`). Si no lo tiene, el commit del workflow fallará con 403.

Al pushear a `main` cambios en `src/zetronpoc/firmware/mmdvm_hs_512/`, el workflow:
1. Instala el toolchain ARM
2. Clona `juribeparada/MMDVM_HS` + submódulo `STM32F10X_Lib`
3. Aplica los 3 patches
4. Verifica que quedaron aplicados (`verify_patches.py`)
5. Compila con `make` (standalone, sin bootloader)
6. Publica `firmware_pocsag512_149mhz.bin` como **Release** descargable

URL de descarga:
```
https://github.com/gatoambroggio/mediguard-os-copy/releases/download/pocsag512-149mhz-latest/firmware_pocsag512_149mhz.bin
```

### Opción B: Local (Raspberry Pi o PC Linux)

```bash
cd src/zetronpoc/firmware/mmdvm_hs_512

# 1. Instalar toolchain ARM
sudo apt install gcc-arm-none-eabi libstdc++-arm-none-eabi-newlib libnewlib-arm-none-eabi

# 2. Clonar y parchear
./clone_and_patch.sh

# 3. Compilar (build standalone, sin bootloader — flashable a 0x0)
./build_firmware.sh
# -> firmware_pocsag512_149mhz.bin
```

---

## Flashear al Jumbospot (STM32)

### Serial — stm32flash (recomendado)

El firmware es **standalone** (sin bootloader USB-DFU): tabla de vectores en
`0x0`, flashable directo a `0x08000000` por UART. No requiere modo DFU ni
puente BOOT0.

```bash
sudo apt install stm32flash
./flash.sh firmware_pocsag512_149mhz.bin
# equivale a: stm32flash -b 115200 -v -w firmware_pocsag512_149mhz.bin -g 0x0 -R /dev/ttyAMA0
```

Si te da **NACK al ~67%** (write protection activada de fábrica):

```bash
sudo stm32flash -k /dev/ttyAMA0     # quita write protection (WRP)
# DESCONECTAR Y RECONECTAR la placa (power-cycle obligatorio tras -k)
./flash.sh firmware_pocsag512_149mhz.bin
```

> Si `-k` solo no alcanza (RDP Level 1): `sudo stm32flash -u /dev/ttyAMA0`
> antes del `-k` (esto borra todo el flash, incluyendo bootloader de fábrica).

---

## Verificar

```bash
sudo systemctl restart mmdvmhost
journalctl -u mmdvmhost -f | grep -i pocsag
```

Desde el panel admin (Diagnóstico → Test page) dispará un page a un cap de 512.
El pager debe mostrar **texto legible**.

### Verificar baud real con RTL-SDR

```bash
./verify_baud.sh 149255000 1234567
# 256 Hz = 512 baud (OK)
# 600 Hz = 1200 baud (el flag NO tomo efecto)
```

---

## Fallback reversible

### Volver a 1200 baud
Recompilar **sin** `-DPOCSAG_512` (el `#else` restaura REG3 de 1200 baud).
El patch de `ADF7021.h` está envuelto en `#if defined(POCSAG_512) / #else`.

### Volver a 148 MHz max
Recompilar **sin** `-DPOCSAG_149MHZ` (el `#else` restaura VHF1_MAX=148 MHz).
El patch de `IO.h` está envuelto en `#if defined(POCSAG_149MHZ) / #else`.

---

## Archivos

| Archivo | Qué hace |
|---|---|
| `patches/Config.h` | Config.h completo para NANO_HOTSPOT (BI7JTA) |
| `patches/IO.h.patch` | VHF1_MAX extendido a 150 MHz |
| `patches/ADF7021.h.patch` | REG3 POCSAG 512 baud |
| `tools/verify_patches.py` | Verifica que los 3 patches quedaron aplicados |
| `tools/find_pocsag_clock.py` | Reporte de diagnóstico del bit-clock (referencia) |
| `tools/reg3_calc.py` | Recalcula R3 para cualquier baud/XTAL (referencia) |
| `clone_and_patch.sh` | Clona MMDVM_HS oficial, aplica patches y verifica |
| `build_firmware.sh` | Compila con `make bl` y copia el `.bin` |
| `flash.sh` | Flashea el `.bin` al STM32 con `dfu-util` |
| `verify_baud.sh` | Verifica el baud real de TX con RTL-SDR |
| `workflow-template.yml` | Workflow de GitHub Actions (publicado como `.github/workflows/build-firmware.yml`) |

---

## TCXO

TCXO **14.7456 MHz** (confirmado del string de firmware `MMDVM_HS-v1.6.0 20200803
14.7456MHz`). Si tu placa es 12.2880 MHz, usá `-DADF7021_12_2880` en lugar de
`-DADF7021_14_7456` en `patches/Config.h`.