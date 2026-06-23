-- =============================================================================
-- appstack — MRO Spare Parts Store : Phase 1 schema
-- Owned tables: auth-service -> users ; catalog-service -> categories, parts
-- Runs once on a fresh Postgres volume (docker-entrypoint-initdb.d).
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid()

-- ----------------------------------------------------------------------------
-- users  (auth-service)
-- ----------------------------------------------------------------------------
CREATE TABLE users (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email         text UNIQUE NOT NULL,
    password_hash text NOT NULL,
    role          text NOT NULL DEFAULT 'staff' CHECK (role IN ('admin','staff')),
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- categories  (catalog-service)
-- ----------------------------------------------------------------------------
CREATE TABLE categories (
    id   serial PRIMARY KEY,
    name text UNIQUE NOT NULL,
    slug text UNIQUE NOT NULL
);

-- ----------------------------------------------------------------------------
-- parts  (catalog-service)
-- stock_qty lives here for Phase 1 demo; inventory-service refines it later.
-- ----------------------------------------------------------------------------
CREATE TABLE parts (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    part_number text UNIQUE NOT NULL,
    name        text NOT NULL,
    description text,
    category_id int NOT NULL REFERENCES categories(id),
    unit_price  numeric(10,2) NOT NULL DEFAULT 0,
    uom         text NOT NULL DEFAULT 'EA',
    stock_qty   int  NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_parts_category ON parts(category_id);
CREATE INDEX idx_parts_name_trgm ON parts USING gin (to_tsvector('english', name));
