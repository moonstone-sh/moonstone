CREATE TABLE IF NOT EXISTS schema_migrations (
  version INTEGER PRIMARY KEY,
  applied_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS artifacts (
  artifact_hash TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  version TEXT NOT NULL,
  kind TEXT NOT NULL,
  target TEXT NOT NULL,
  lua_abi TEXT,
  runtime TEXT,
  path TEXT NOT NULL,
  manifest_path TEXT NOT NULL,
  lua_api TEXT,
  runtime_artifact_hash TEXT,
  resolver TEXT,
  source TEXT,
  native_compat_required INTEGER DEFAULT 0,
  description TEXT,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS artifact_name_trigrams (
  artifact_hash TEXT NOT NULL,
  trigram TEXT NOT NULL,
  PRIMARY KEY (artifact_hash, trigram),
  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
);

CREATE TABLE IF NOT EXISTS provides_runtime (
  artifact_hash TEXT NOT NULL,
  name TEXT NOT NULL,
  version TEXT NOT NULL,
  abi TEXT NOT NULL,
  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
);

CREATE TABLE IF NOT EXISTS provides_bin (
  artifact_hash TEXT NOT NULL,
  name TEXT NOT NULL,
  path TEXT NOT NULL,
  entry_point TEXT,
  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
);

CREATE TABLE IF NOT EXISTS provides_bin_lua (
  artifact_hash TEXT NOT NULL,
  name TEXT NOT NULL,
  path TEXT NOT NULL,
  entry_point TEXT,
  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
);

CREATE TABLE IF NOT EXISTS provides_headers (
  artifact_hash TEXT NOT NULL,
  name TEXT NOT NULL,
  path TEXT NOT NULL,
  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
);

CREATE TABLE IF NOT EXISTS provides_native_lib (
  artifact_hash TEXT NOT NULL,
  name TEXT NOT NULL,
  path TEXT NOT NULL,
  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
);

CREATE TABLE IF NOT EXISTS provides_lua_module (
  artifact_hash TEXT NOT NULL,
  name TEXT NOT NULL,
  path TEXT NOT NULL,
  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
);

CREATE TABLE IF NOT EXISTS provides_lua_cmodule (
  artifact_hash TEXT NOT NULL,
  name TEXT NOT NULL,
  path TEXT NOT NULL,
  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
);

CREATE TABLE IF NOT EXISTS provides_script (
  artifact_hash TEXT NOT NULL,
  name TEXT NOT NULL,
  path TEXT NOT NULL,
  entry_point TEXT,
  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
);

CREATE TABLE IF NOT EXISTS provides_asset (
  artifact_hash TEXT NOT NULL,
  name TEXT NOT NULL,
  path TEXT NOT NULL,
  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
);

CREATE TABLE IF NOT EXISTS provides_ballad_plugin (
  artifact_hash TEXT NOT NULL,
  name TEXT NOT NULL,
  path TEXT NOT NULL,
  entry_point TEXT,
  module TEXT,
  FOREIGN KEY(artifact_hash) REFERENCES artifacts(artifact_hash)
);

CREATE TABLE IF NOT EXISTS links (
  name TEXT PRIMARY KEY,
  path TEXT NOT NULL,
  version TEXT NOT NULL,
  kind TEXT NOT NULL,
  mode TEXT NOT NULL,
  registered_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
