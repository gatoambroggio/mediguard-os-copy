-- seed.sql - ZetronPOC v2.0 - Valores por defecto (Zetron 640 / DaptX-Xtra)
-- Config es INSERT OR IGNORE para no pisar valores existentes en --update.

-- === Sistema / version ===
INSERT OR IGNORE INTO config(clave,valor) VALUES('version','2.0');
INSERT OR IGNORE INTO config(clave,valor) VALUES('pocsag_mode','client');

-- === PBX / SIP (FreePBX) ===
INSERT OR IGNORE INTO config(clave,valor) VALUES('hospital_pbx_ip','192.168.2.97');
INSERT OR IGNORE INTO config(clave,valor) VALUES('hospital_pbx_port','5060');
INSERT OR IGNORE INTO config(clave,valor) VALUES('transport_bind','0.0.0.0:5060');
INSERT OR IGNORE INTO config(clave,valor) VALUES('transport_protocol','udp');
INSERT OR IGNORE INTO config(clave,valor) VALUES('codecs','ulaw,alaw');
INSERT OR IGNORE INTO config(clave,valor) VALUES('retry_interval','60');
INSERT OR IGNORE INTO config(clave,valor) VALUES('expiration','3600');

-- === IVR ===
INSERT OR IGNORE INTO config(clave,valor) VALUES('mensaje_timeout','10');
INSERT OR IGNORE INTO config(clave,valor) VALUES('ptt_preactivo','0.5');
INSERT OR IGNORE INTO config(clave,valor) VALUES('digit_timeout','5');
INSERT OR IGNORE INTO config(clave,valor) VALUES('response_timeout','15');
INSERT OR IGNORE INTO config(clave,valor) VALUES('test_mode','1');

-- === ZETRON 640 - Encoder POCSAG ===
INSERT OR IGNORE INTO config(clave,valor) VALUES('baudios_default','1200');
INSERT OR IGNORE INTO config(clave,valor) VALUES('preamble_bits','576');
INSERT OR IGNORE INTO config(clave,valor) VALUES('warmup_512_ms','750');
INSERT OR IGNORE INTO config(clave,valor) VALUES('warmup_1200_ms','1500');
INSERT OR IGNORE INTO config(clave,valor) VALUES('warmup_2400_ms','1500');
INSERT OR IGNORE INTO config(clave,valor) VALUES('fsk_deviation_khz','4.5');
INSERT OR IGNORE INTO config(clave,valor) VALUES('fsk_deviation_baseband_hz','450');
INSERT OR IGNORE INTO config(clave,valor) VALUES('fsk_levels','2');
INSERT OR IGNORE INTO config(clave,valor) VALUES('function_mode','alphanumeric');
INSERT OR IGNORE INTO config(clave,valor) VALUES('sample_rate','22050');
INSERT OR IGNORE INTO config(clave,valor) VALUES('audio_gain','80');
INSERT OR IGNORE INTO config(clave,valor) VALUES('invert_audio','0');
INSERT OR IGNORE INTO config(clave,valor) VALUES('gaussian_bt','0.5');
INSERT OR IGNORE INTO config(clave,valor) VALUES('preamble_idle_repeat','1');

-- === DAPT-X XTRA - Transmisor ===
INSERT OR IGNORE INTO config(clave,valor) VALUES('tx_enable','1');
INSERT OR IGNORE INTO config(clave,valor) VALUES('tx_frequency','155.0000');
INSERT OR IGNORE INTO config(clave,valor) VALUES('tx_power','5');
INSERT OR IGNORE INTO config(clave,valor) VALUES('channel_spacing','25');
INSERT OR IGNORE INTO config(clave,valor) VALUES('modulation_type','NFM');
INSERT OR IGNORE INTO config(clave,valor) VALUES('tx_deviation_khz','4.5');
INSERT OR IGNORE INTO config(clave,valor) VALUES('audio_input_gain','70');
INSERT OR IGNORE INTO config(clave,valor) VALUES('squelch_level','3');
INSERT OR IGNORE INTO config(clave,valor) VALUES('preemphasis','1');
INSERT OR IGNORE INTO config(clave,valor) VALUES('high_pass_filter_hz','300');
INSERT OR IGNORE INTO config(clave,valor) VALUES('low_pass_filter_hz','3000');
INSERT OR IGNORE INTO config(clave,valor) VALUES('antenna_impedance','50');

-- === GPIO / PTT ===
INSERT OR IGNORE INTO config(clave,valor) VALUES('gpio_chip','gpiochip0');
INSERT OR IGNORE INTO config(clave,valor) VALUES('gpio_pin','17');

-- === Admin ===
INSERT OR IGNORE INTO config(clave,valor) VALUES('admin_user','admin');
INSERT OR IGNORE INTO config(clave,valor) VALUES('admin_pass','admin123');

-- === SMTP ===
INSERT OR IGNORE INTO config(clave,valor) VALUES('smtp_host','');
INSERT OR IGNORE INTO config(clave,valor) VALUES('smtp_port','587');
INSERT OR IGNORE INTO config(clave,valor) VALUES('smtp_user','');
INSERT OR IGNORE INTO config(clave,valor) VALUES('smtp_pass','');
INSERT OR IGNORE INTO config(clave,valor) VALUES('smtp_from','');
INSERT OR IGNORE INTO config(clave,valor) VALUES('smtp_secure','tls');
INSERT OR IGNORE INTO config(clave,valor) VALUES('backup_email','');

-- === Tema (futurista) ===
INSERT OR IGNORE INTO config(clave,valor) VALUES('theme_acc','#00f0ff');
INSERT OR IGNORE INTO config(clave,valor) VALUES('theme_acc2','#ff00d4');
INSERT OR IGNORE INTO config(clave,valor) VALUES('theme_bg','#05060f');
INSERT OR IGNORE INTO config(clave,valor) VALUES('theme_panel','#0a0f1f');

-- === Extensiones 2000-2010 ===
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2000','CAMBIAR_2000','from-hospital','Interno hospitalario 2000',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2001','CAMBIAR_2001','from-hospital','Interno hospitalario 2001',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2002','CAMBIAR_2002','from-hospital','Interno hospitalario 2002',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2003','CAMBIAR_2003','from-hospital','Interno hospitalario 2003',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2004','CAMBIAR_2004','from-hospital','Interno hospitalario 2004',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2005','CAMBIAR_2005','from-hospital','Interno hospitalario 2005',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2006','CAMBIAR_2006','from-hospital','Interno hospitalario 2006',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2007','CAMBIAR_2007','from-hospital','Interno hospitalario 2007',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2008','CAMBIAR_2008','from-hospital','Interno hospitalario 2008',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2009','CAMBIAR_2009','from-hospital','Interno hospitalario 2009',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2010','CAMBIAR_2010','from-hospital','Interno hospitalario 2010',1);

-- === Pager de prueba ===
INSERT OR IGNORE INTO pagers(codigo,cap_code,nombre,apellido,area,baudios,funcion,descripcion,activo)
  VALUES('100','1234567','Guardia','Medica','Emergencias',1200,'alphanumeric','Pager de prueba',1);

-- === Grupo de prueba ===
INSERT OR IGNORE INTO grupos(codigo,nombre,baudios,activo) VALUES('CODE','Codigo unico',1200,1);
INSERT OR IGNORE INTO grupo_miembros(grupo_id,cap_code,orden)
  SELECT g.id,'1234567',0 FROM grupos g WHERE g.codigo='CODE';

-- === Plantilla ===
INSERT OR IGNORE INTO plantillas(nombre,mensaje,categoria,orden,activo)
  VALUES('Emergencia','URGENCIA: ','urgencias',1,1);