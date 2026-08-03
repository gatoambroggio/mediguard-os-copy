-- ============================================================================
-- database/seed.sql - Datos de ejemplo hospitalarios
-- ============================================================================
INSERT OR IGNORE INTO codigos (codigo,tipo,cap_code,baudios,descripcion) VALUES
 ('11','grupo','100001',1200,'Código Azul (paro cardíaco)'),
 ('12','broadcast','200001',1200,'Código Rojo (incendio)'),
 ('13','broadcast','200002',1200,'Código Blanco (evacuación)'),
 ('21','individual','300021',1200,'Médico de guardia'),
 ('22','individual','300022',1200,'Enfermero de guardia'),
 ('99','individual','300099',512,'Prueba de sistema');

INSERT OR IGNORE INTO grupos (nombre,cap_code,baudios) VALUES
 ('Guardia médica','100001',1200),
 ('Emergencias','200001',1200);

INSERT OR IGNORE INTO grupo_miembros (grupo_id,cap_code) VALUES
 (1,'300021'), (1,'300022'),
 (2,'300021'), (2,'300022');