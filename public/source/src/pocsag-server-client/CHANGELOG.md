# Pogsac - Registro de cambios

## v1.02 (2026-08-03)
- FIX registro SIP contra FreePBX: cambio de patron. Antes habia un unico
  endpoint `hospital-inbound` + `identify` por IP, que es fragil con FreePBX.
  Ahora hay un endpoint por extension (nombrado 2000, 2001, ... 2010) que
  matchea por el usuario del Request-URI. Es el patron estandar y confiable
  para Asterisk como cliente de FreePBX.
- AORs con `max_contacts=1` + `remove_existing=yes` y endpoints con
  `rewrite_contact=yes` para soportar NAT correctamente.
- "Aplicar a Asterisk" ahora ejecuta `pjsip send register` despues del reload
  para forzar el registro inmediato (no espera al retry_interval).
- Corregidas referencias residuales a internos 3000-3003 -> 2000-2010 en
  panel admin, instalador y backend.

## v1.01
- Internos 2000-2010 apuntando a 192.168.2.97. Registros SIP sin from_user
  y sin puerto explicito para maxima compatibilidad con FreePBX.

## v1.0
- Renombrado del proyecto a Pogsac. Encoder POCSAG con todos sus parametros
  (baudios, preambulo, FSK, niveles, modo de funcion) editables desde el
  panel admin. IVR identico al 2184. 10 internos gestionables contra FreePBX.