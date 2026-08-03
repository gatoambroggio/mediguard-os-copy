CREATE TABLE IF NOT EXISTS pagers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo TEXT UNIQUE NOT NULL,
  cap_code TEXT NOT NULL,
  nombre TEXT,
  apellido TEXT,
  area TEXT,
  baudios INTEGER DEFAULT 1200,
  tipo TEXT DEFAULT 'individual',
  descripcion TEXT,
  activo INTEGER DEFAULT 1
);
CREATE TABLE IF NOT EXISTS grupos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo TEXT UNIQUE NOT NULL,
  nombre TEXT,
  baudios INTEGER DEFAULT 1200,
  activo INTEGER DEFAULT 1
);
CREATE TABLE IF NOT EXISTS grupo_miembros (
  grupo_id INTEGER REFERENCES grupos(id) ON DELETE CASCADE,
  cap_code TEXT NOT NULL,
  orden INTEGER DEFAULT 0,
  PRIMARY KEY (grupo_id, cap_code)
);
CREATE TABLE IF NOT EXISTS config (
  clave TEXT PRIMARY KEY,
  valor TEXT
);
CREATE TABLE IF NOT EXISTS extensiones (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  numero TEXT UNIQUE NOT NULL,
  password TEXT,
  contexto TEXT DEFAULT 'pocsag-incoming',
  descripcion TEXT,
  activo INTEGER DEFAULT 1
);
CREATE TABLE IF NOT EXISTS bitacora (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fecha_hora DATETIME DEFAULT (datetime('now','localtime')),
  interno_origen TEXT,
  codigo TEXT,
  cap_code TEXT,
  mensaje TEXT,
  baudios INTEGER,
  estado TEXT,
  observaciones TEXT
);
CREATE INDEX IF NOT EXISTS idx_bitacora_fecha ON bitacora(fecha_hora);
CREATE INDEX IF NOT EXISTS idx_bitacora_codigo ON bitacora(codigo);
CREATE INDEX IF NOT EXISTS idx_bitacora_cap ON bitacora(cap_code);
CREATE INDEX IF NOT EXISTS idx_bitacora_estado ON bitacora(estado);
CREATE INDEX IF NOT EXISTS idx_bitacora_interno ON bitacora(interno_origen);
CREATE INDEX IF NOT EXISTS idx_pagers_codigo ON pagers(codigo);
CREATE INDEX IF NOT EXISTS idx_pagers_cap ON pagers(cap_code);
CREATE INDEX IF NOT EXISTS idx_grupos_codigo ON grupos(codigo);
CREATE INDEX IF NOT EXISTS idx_extensiones_numero ON extensiones(numero);
CREATE TABLE IF NOT EXISTS cola_envios (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fecha_encola DATETIME DEFAULT (datetime('now','localtime')),
  fecha_procesado DATETIME,
  codigo TEXT NOT NULL,
  cap_code TEXT,
  mensaje TEXT,
  baudios INTEGER,
  origen TEXT DEFAULT 'web',
  estado TEXT DEFAULT 'pendiente',
  intentos INTEGER DEFAULT 0,
  observaciones TEXT,
  proximo_intento DATETIME
);
CREATE INDEX IF NOT EXISTS idx_cola_estado ON cola_envios(estado);
CREATE INDEX IF NOT EXISTS idx_cola_fecha ON cola_envios(fecha_encola);
CREATE TABLE IF NOT EXISTS plantillas (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  nombre TEXT NOT NULL,
  mensaje TEXT NOT NULL,
  categoria TEXT DEFAULT 'general',
  activo INTEGER DEFAULT 1,
  orden INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS envios_programados (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo TEXT NOT NULL,
  mensaje TEXT NOT NULL,
  origen TEXT DEFAULT 'web',
  tipo TEXT DEFAULT 'unico',
  fecha_programada DATETIME,
  recurrencia_dia INTEGER DEFAULT 0,
  recurrencia_hora TEXT DEFAULT '08:00',
  proxima_ejecucion DATETIME,
  activo INTEGER DEFAULT 1,
  ultima_ejecucion DATETIME
);
CREATE INDEX IF NOT EXISTS idx_prog_prox ON envios_programados(proxima_ejecucion);
CREATE INDEX IF NOT EXISTS idx_prog_act ON envios_programados(activo);
CREATE TABLE IF NOT EXISTS auditoria (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fecha_hora DATETIME DEFAULT (datetime('now','localtime')),
  usuario TEXT,
  accion TEXT,
  entidad TEXT,
  entidad_id TEXT,
  detalle TEXT,
  ip TEXT
);
CREATE INDEX IF NOT EXISTS idx_aud_fecha ON auditoria(fecha_hora);
CREATE INDEX IF NOT EXISTS idx_aud_entidad ON auditoria(entidad);