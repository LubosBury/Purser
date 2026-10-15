import GRDB

enum Migrations {
    /// Contract K2, migration v1. Never edit: add v2, v3, ... instead.
    static let v1 = """
    CREATE TABLE workspace (id TEXT PRIMARY KEY, config_json TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE sync_run (
      id INTEGER PRIMARY KEY AUTOINCREMENT, trigger TEXT NOT NULL, status TEXT NOT NULL,
      started_at TEXT NOT NULL, finished_at TEXT, request_count INTEGER NOT NULL DEFAULT 0,
      complete_scopes_json TEXT NOT NULL DEFAULT '[]');
    CREATE TABLE territory (code TEXT PRIMARY KEY, currency TEXT NOT NULL);
    CREATE TABLE product (
      asc_id TEXT PRIMARY KEY, product_id TEXT NOT NULL, kind TEXT NOT NULL, info_json TEXT NOT NULL,
      first_sync INTEGER NOT NULL REFERENCES sync_run(id), last_sync INTEGER NOT NULL REFERENCES sync_run(id));
    CREATE TABLE observation (
      id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, asc_id TEXT NOT NULL, product_asc_id TEXT NOT NULL,
      cell_key TEXT NOT NULL, raw_json TEXT NOT NULL, content_hash TEXT NOT NULL,
      first_sync INTEGER NOT NULL REFERENCES sync_run(id), last_sync INTEGER NOT NULL REFERENCES sync_run(id),
      provenance TEXT NOT NULL, expired INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX observation_cell ON observation(cell_key, last_sync);
    CREATE UNIQUE INDEX observation_identity ON observation(kind, asc_id, content_hash);
    CREATE TABLE price_point (
      id TEXT PRIMARY KEY, product_asc_id TEXT NOT NULL, territory TEXT NOT NULL, plan_type TEXT,
      customer_price TEXT NOT NULL, proceeds TEXT, fetched_at TEXT NOT NULL);
    CREATE INDEX price_point_lookup ON price_point(product_asc_id, territory, plan_type);
    CREATE TABLE plan (
      id TEXT PRIMARY KEY, origin TEXT NOT NULL, spec_json TEXT NOT NULL, import_json TEXT, binding_json TEXT NOT NULL,
      base_sync INTEGER NOT NULL, state TEXT NOT NULL, pause_reason TEXT, end_reason TEXT,
      plan_hash TEXT NOT NULL, verdict_hash TEXT NOT NULL, verdicts_json TEXT NOT NULL, excluded_json TEXT NOT NULL,
      product_states_json TEXT NOT NULL DEFAULT '{}', reason TEXT, confirmation_level INTEGER NOT NULL,
      app_build TEXT NOT NULL, estimate_requests INTEGER NOT NULL, estimate_minutes INTEGER NOT NULL,
      replan_of TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, heartbeat_at TEXT);
    CREATE TABLE item (
      plan_id TEXT NOT NULL REFERENCES plan(id), seq INTEGER NOT NULL, op TEXT NOT NULL, cell_key TEXT NOT NULL,
      before_json TEXT NOT NULL, target_json TEXT NOT NULL, payload_json TEXT NOT NULL, natural_key TEXT NOT NULL,
      depends_on_json TEXT NOT NULL, rules_json TEXT NOT NULL, state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
      asc_id TEXT, error_json TEXT, verified_at TEXT, effective_at TEXT, superseded_by TEXT,
      flags_json TEXT NOT NULL DEFAULT '[]', PRIMARY KEY (plan_id, seq));
    CREATE INDEX item_natural_key ON item(natural_key);
    CREATE INDEX item_asc_id ON item(asc_id);
    CREATE TABLE finding (
      id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, rule TEXT, cell_key TEXT NOT NULL,
      fingerprint TEXT NOT NULL UNIQUE, message TEXT NOT NULL, first_sync INTEGER NOT NULL, last_sync INTEGER NOT NULL,
      plan_id TEXT, ack_reason TEXT, ack_at TEXT);
    CREATE TABLE offer_code_registry (offer_code TEXT PRIMARY KEY, product_asc_id TEXT NOT NULL, first_seen_sync INTEGER NOT NULL);
    CREATE TABLE audit_event (
      seq INTEGER PRIMARY KEY, ts TEXT NOT NULL, type TEXT NOT NULL, actor TEXT NOT NULL,
      refs_json TEXT NOT NULL, payload_json TEXT NOT NULL, prev_hash TEXT NOT NULL, hash TEXT NOT NULL);
    CREATE TRIGGER audit_no_update BEFORE UPDATE ON audit_event BEGIN SELECT RAISE(ABORT, 'audit_event is append-only'); END;
    CREATE TRIGGER audit_no_delete BEFORE DELETE ON audit_event BEGIN SELECT RAISE(ABORT, 'audit_event is append-only'); END;
    """

    /// Migration v2: subscription groups and the versions of every localization owner (the result of the
    /// owner's last complete read). The texts are observations of kind LOCALIZATION. Never edit: add v3 instead.
    static let v2 = """
    CREATE TABLE subscription_group (asc_id TEXT PRIMARY KEY, reference_name TEXT NOT NULL,
      first_sync INTEGER NOT NULL REFERENCES sync_run(id), last_sync INTEGER NOT NULL REFERENCES sync_run(id));
    CREATE TABLE metadata_version (asc_id TEXT PRIMARY KEY, owner_key TEXT NOT NULL, number INTEGER NOT NULL, state TEXT NOT NULL,
      last_sync INTEGER NOT NULL REFERENCES sync_run(id));
    CREATE INDEX metadata_version_owner ON metadata_version(owner_key);
    """

    /// Migration v3: a counter of changes to `price_point` (one row), bumped in the writer's transaction, so a reader
    /// can keep its price point index while the generation stays the same (CatalogStore). Never edit: add v4 instead.
    static let v3 = """
    CREATE TABLE price_point_generation (value INTEGER NOT NULL);
    INSERT INTO price_point_generation (value) VALUES (0);
    CREATE TRIGGER price_point_generation_insert AFTER INSERT ON price_point BEGIN UPDATE price_point_generation SET value = value + 1; END;
    CREATE TRIGGER price_point_generation_update AFTER UPDATE ON price_point BEGIN UPDATE price_point_generation SET value = value + 1; END;
    CREATE TRIGGER price_point_generation_delete AFTER DELETE ON price_point BEGIN UPDATE price_point_generation SET value = value + 1; END;
    """

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: v1)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: v2)
        }
        migrator.registerMigration("v3") { db in
            try db.execute(sql: v3)
        }
        return migrator
    }
}
