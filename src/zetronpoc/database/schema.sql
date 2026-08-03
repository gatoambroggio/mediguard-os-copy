-- schema.sql - ZetronPOC v2.0 (Zetron 640 / DaptX-Xtra)
-- SQLite schema. Config es clave/valor para maxima flexibilidad.

CREATE TABLE IF NOT EXISTS config (
  clave   TEXT PRIMARY KEY,
  valor   TEXT
);

CREATE TABLE IF NOT EXISTS extensiones (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  numero      TEXT UNIQUE NOT NULL,
  password    TEXT DEFAULT '',
  contexto    TEXT DEFAULT 'from-hospital',
  descripcion TEXT DEFAULT '',
  activo      INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS pagers (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo      TEXT UNIQUE NOT NULL,
  cap_code    TEXT NOT NULL,
  nombre      TEXT DEFAULT '',
  apellido    TEXT DEFAULT '',
  area        TEXT DEFAULT '',
  baudios     INTEGER DEFAULT 1200,
  funcion     TEXT DEFAULT 'alphanumeric',
  descripcion TEXT DEFAULT '',
  activo      INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS grupos (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo  TEXT UNIQUE NOT NULL,
  nombre  TEXT DEFAULT '',
  baudios INTEGER DEFAULT 1200,
  activo  INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS grupo_miembros (
  grupo_id INTEGER NOT NULL,
  cap_code TEXT NOT NULL,
  orden    INTEGER DEFAULT 0,
  PRIMARY KEY (grupo_id, cap_code)
);

CREATE TABLE IF NOT EXISTS bitacora (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  fecha_hora    TEXT,
  interno_origen TEXT,
  codigo        TEXT,
  cap_code      TEXT,
  mensaje       TEXT,
  baudios       INTEGER,
  estado        TEXT,
  observaciones TEXT
);

CREATE TABLE IF NOT EXISTS cola_envios (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  fecha_encola    TEXT,
  codigo          TEXT,
  cap_code        TEXT,
  mensaje         TEXT,
  baudios         INTEGER,
  origen         TEXT,
  estado          TEXT DEFAULT 'pendiente',
  intentos        INTEGER DEFAULT 0,
  fecha_procesado TEXT,
  observaciones   TEXT DEFAULT '',
  proximo_intento TEXT
);

CREATE TABLE IF NOT EXISTS plantillas (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  nombre    TEXT,
  mensaje   TEXT,
  categoria TEXT DEFAULT 'general',
  orden     INTEGER DEFAULT 0,
  activo    INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS envios_programados (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo            TEXT,
  mensaje           TEXT,
  origen            TEXT DEFAULT 'web',
  tipo              TEXT DEFAULT 'unico',
  fecha_programada  TEXT,
  recurrencia_dia   INTEGER DEFAULT 0,
  recurrencia_hora  TEXT DEFAULT '08:00',
  ultima_ejecucion  TEXT,
  proxima_ejecucion TEXT,
  activo            INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS auditoria (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  fecha_hora  TEXT,
  usuario     TEXT,
  accion      TEXT,
  entidad     TEXT,
  entidad_id  TEXT,
  detalle     TEXT,
  ip          TEXT
);

CREATE INDEX IF NOT EXISTS idx_bitacora_fecha ON bitacora(fecha_hora);
CREATE INDEX IF NOT EXISTS idx_cola_estado ON cola_envios(estado);