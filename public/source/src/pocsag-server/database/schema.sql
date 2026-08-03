-- ============================================================================
-- database/schema.sql - Esquema de la base de datos POCSAG
-- ============================================================================

-- Códigos de paginación mapeados a destinatarios o grupos
CREATE TABLE IF NOT EXISTS codigos (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo      TEXT UNIQUE NOT NULL,         -- ej. "11", "2184"
  tipo        TEXT NOT NULL,                 -- 'individual' | 'grupo' | 'broadcast'
  cap_code    TEXT,                          -- capcode/ric del pager o del grupo
  baudios     INTEGER DEFAULT 1200,          -- 512 | 1200 | 2400
  descripcion TEXT,
  activo      INTEGER DEFAULT 1
);

-- Grupos de pagers
CREATE TABLE IF NOT EXISTS grupos (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  nombre    TEXT UNIQUE NOT NULL,
  cap_code  TEXT,
  baudios   INTEGER DEFAULT 1200
);

CREATE TABLE IF NOT EXISTS grupo_miembros (
  grupo_id  INTEGER REFERENCES grupos(id) ON DELETE CASCADE,
  cap_code TEXT NOT NULL,
  PRIMARY KEY (grupo_id, cap_code)
);

-- Bitácora de envíos (auditoría hospitalaria)
CREATE TABLE IF NOT EXISTS bitacora (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  fecha_hora    DATETIME DEFAULT CURRENT_TIMESTAMP,
  interno_origen TEXT,
  codigo        TEXT,
  cap_code      TEXT,
  mensaje       TEXT,
  baudios       INTEGER,
  estado        TEXT,                       -- 'enviado' | 'error'
  observaciones TEXT
);

CREATE INDEX IF NOT EXISTS idx_bitacora_fecha ON bitacora(fecha_hora);
CREATE INDEX IF NOT EXISTS idx_codigos_codigo ON codigos(codigo);