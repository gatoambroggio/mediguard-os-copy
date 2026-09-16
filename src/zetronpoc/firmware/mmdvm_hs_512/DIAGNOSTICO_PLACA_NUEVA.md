# Diagnóstico de placa nueva — 16 Sep 2026

## Problema
Placa Nano hotSPOT nueva (clon chino, sin display, TCXO 14.7456 MHz) no responde
a MMDVMHost. El STM32 responde al frame GET_VERSION pero con **string de versión
vacío**, y MMDVMHost reporta "Unable to read the firmware version after six
attempts". LED rojo en loop rápido.

El mismo firmware custom (POCSAG 512/149MHz) funcionaba en la placa anterior
(que se quemó). La placa nueva tiene el mismo TCXO (14.7456 MHz).

## Diagnóstico

### Síntomas confirmados
1. MMDVMHost no puede leer la versión de firmware (6 intentos fallidos)
2. `mmdvm_detect_port.py` detecta el puerto `/dev/ttyAMA0` (el frame 0xE0 llega)
3. `mmdvm_detect_port.py --version` devuelve el puerto pero **sin string de versión**
4. LED rojo parpadeando muy rápido (crash loop del STM32)
5. TCXO confirmado: 14.7456 MHz (mismo que la placa vieja)

### Causa probable
El firmware custom con `#define DUPLEX` está crasheando en esta variante de placa.
Hay un dead_end registrado: *"Defining DUPLEX for single-ADF7021 Jumbospot boards
caused the STM32 to hang on spurious interrupts from PA5, preventing UART
response."*

La placa anterior toleraba DUPLEX; la nueva no. El STM32 arranca parcialmente
(responde al GET_VERSION con un frame 0xE0) pero crashea antes de inicializar
el string de versión completo.

### Issue #159 de juribeparada/MMDVM_HS
Confirma que los clones chinos blancos vienen en versiones diferentes:
- Algunos con BOOT1 (PB2, pin 20) NO conectado a GND → "failed to init device"
- Algunos con el modem bloqueado de fábrica
- Configuraciones de hardware que varían entre lotes

## Plan de acción

### Paso 1: Flash firmware oficial (descartar falla física)
```bash
cd /opt/zetronpoc/firmware/mmdvm_hs_512
sudo ./flash_official.sh
```
Esto descarga `generic_gpio_fw.bin` (v1.5.2, SIMPLEX oficial) y lo flashea.
Si la placa responde con un string de versión completo → hardware OK, el
problema es nuestro firmware custom.

### Paso 2: Si el oficial funciona → recompilar custom en SIMPLEX
Comentar `#define DUPLEX` en `patches/Config.h` y recompilar:
```bash
./build_firmware.sh
sudo ./flash.sh firmware_pocsag512_149mhz.bin
```

### Paso 3: Si el oficial TAMPOCO funciona
- Probar `sudo stm32flash -u /dev/ttyAMA0` (borra todo, quita RDP)
- Re-flashear el oficial
- Si sigue sin responder: posible BOOT1 (PB2) flotante → soldar a GND