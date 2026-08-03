# ZETRON 640 · DAPT-X XTRA (ZetronPOC v2.0)

Sistema de paginación hospitalaria **POCSAG** de alta disponibilidad, modo **cliente**
de una central **FreePBX**. Encoder POCSAG real (BCH 31,21) parametrizable + transmisor
configurable, todo desde un panel web futurista.

## Novedades v2.0

- **Encoder Zetron 640**: codewords POCSAG con BCH(31,21) + paridad par (decodifican
  pagers reales), FSK con filtrado Gaussiano configurable (BT), baudios/preámbulo/
  desviación/niveles/modo/sample-rate/ganancia/inversión todo editable desde el admin.
- **Transmisor DaptX-Xtra**: frecuencia TX, potencia, espacio de canal, modulación,
  desviación TX, ganancia de entrada, squelch, preemphasis, filtros pasaalto/pasabajo,
  impedancia, TX enable — todo parametrizable.
- **Panel futurista**: glassmorphism, neón cian/magenta, grilla animada, tipografía
  Orbitron/JetBrains Mono. Responsive.
- **Instalador con limpieza previa**: detecta y elimina instalaciones anteriores
  (pogsac-server) antes de instalar — ya no queda "tomando" el sistema viejo.
- **Backend reescrito** y reparado: rutas unificadas, importación Excel/CSV, diagnóstico
  SIP, backup/restauración, cola con reintentos.

## Instalación

```bash
curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/src/zetronpoc/instalador.sh | sudo bash
```

Luego en `http://localhost:8080/admin` (admin / admin123):

1. **Parámetros** → IP de la central FreePBX → Guardar
2. **Parámetros** → configurar encoder (Zetron 640) y transmisor (DaptX-Xtra) → Guardar
3. **Extensiones** → editar cada interno con su clave real → **Aplicar a Asterisk**
4. La columna **Registro** debe quedar en `Registered`
5. Probar el IVR: marcar `*99` desde la central (dos beeps)

## Actualizar (sin perder config)

```bash
curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/src/zetronpoc/instalador.sh | sudo bash -s -- --update
```

## Desinstalar todo

```bash
curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/src/zetronpoc/desinstalador.sh | sudo bash -s -- --purge
```

## Verificación por consola

```bash
sudo asterisk -rx "pjsip show registrations"
sudo asterisk -rx "dialplan show from-hospital"
cat /etc/asterisk/pjsip_zetronpoc.conf
``