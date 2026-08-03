INSERT OR IGNORE INTO config (clave, valor) VALUES
 ('pocsag_mode','client'),
 ('hospital_pbx_ip','192.168.2.97'),
 ('hospital_pbx_port','5060'),
 ('transport_bind','0.0.0.0:5060'),
 ('transport_protocol','udp'),
 ('codecs','ulaw,alaw'),
 ('retry_interval','60'),
 ('expiration','3600'),
 ('mensaje_timeout','5'),
 ('ptt_preactivo','0.5'),
 ('digit_timeout','5'),
 ('response_timeout','20'),
 ('max_grupo_capcodes','20'),
 ('test_mode','1'),
 ('admin_user','admin'),
 ('admin_pass','admin123'),
 ('smtp_host',''),
 ('smtp_port','587'),
 ('smtp_user',''),
 ('smtp_pass',''),
 ('smtp_from',''),
 ('smtp_secure','tls'),
 ('backup_email',''),
 ('backup_schedules','[]'),
 ('warmup_512_ms','750'),
 ('warmup_1200_ms','1500'),
 ('warmup_2400_ms','1500'),
 ('preamble_bits','576'),
 ('fsk_deviation_khz','4.5'),
 ('fsk_deviation_baseband_hz','450'),
 ('fsk_levels','2'),
 ('function_mode','alphanumeric'),
 ('baudios_default','1200'),
 ('version','1.0');

INSERT OR IGNORE INTO pagers (codigo,cap_code,nombre,apellido,area,baudios,descripcion) VALUES
 ('10','00002020','Juan','Perez','Guardia Medica',1200,'Medico de guardia'),
 ('11','00002021','Maria','Gomez','Enfermeria',1200,'Enfermera de guardia'),
 ('12','00002022','Carlos','Ruiz','Trauma',1200,'Traumatologo'),
 ('99','00000099','Sistema','Test','Sistemas',512,'Prueba de sistema');

INSERT OR IGNORE INTO grupos (codigo,nombre,baudios) VALUES
 ('20','Codigo Azul - Guardia Medica',1200),
 ('21','Emergencias Generales',1200);

INSERT OR IGNORE INTO grupo_miembros (grupo_id,cap_code,orden) VALUES
 (1,'00002020',1), (1,'00002021',2),
 (2,'00002020',1), (2,'00002021',2), (2,'00002022',3);

INSERT OR IGNORE INTO extensiones (numero,password,contexto,descripcion) VALUES
 ('2000','CAMBIAR_PASSWORD_2000','pocsag-incoming','Interno hospital 2000'),
 ('2001','CAMBIAR_PASSWORD_2001','pocsag-incoming','Interno hospital 2001'),
 ('2002','CAMBIAR_PASSWORD_2002','pocsag-incoming','Interno hospital 2002'),
 ('2003','CAMBIAR_PASSWORD_2003','pocsag-incoming','Interno hospital 2003'),
 ('2004','CAMBIAR_PASSWORD_2004','pocsag-incoming','Interno hospital 2004'),
 ('2005','CAMBIAR_PASSWORD_2005','pocsag-incoming','Interno hospital 2005'),
 ('2006','CAMBIAR_PASSWORD_2006','pocsag-incoming','Interno hospital 2006'),
 ('2007','CAMBIAR_PASSWORD_2007','pocsag-incoming','Interno hospital 2007'),
 ('2008','CAMBIAR_PASSWORD_2008','pocsag-incoming','Interno hospital 2008'),
 ('2009','CAMBIAR_PASSWORD_2009','pocsag-incoming','Interno hospital 2009'),
 ('2010','CAMBIAR_PASSWORD_2010','pocsag-incoming','Interno hospital 2010');

INSERT OR IGNORE INTO plantillas (nombre,mensaje,categoria,orden) VALUES
 ('Codigo Azul','CODIGO AZUL - Emergencia medica - Concurrir de inmediato','emergencia',1),
 ('Codigo Rojo','CODIGO ROJO - Emergencia - Concurrir de inmediato','emergencia',2),
 ('Guardia Medica','Llamado a Guardia Medica - Concurrir','general',3),
 ('Reunion','Convocatoria a reunion - Sala de reuniones','general',4);