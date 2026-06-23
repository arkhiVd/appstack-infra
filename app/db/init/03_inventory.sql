-- =============================================================================
-- Phase 3 — inventory tier (inventory-service)
-- parts.stock_qty (from Phase 1) stays the canonical on-hand number so search
-- and catalog see one figure. stock_movements is the append-only ledger that
-- explains every change to it; bins are physical warehouse locations.
-- =============================================================================

CREATE TABLE bins (
    id   serial PRIMARY KEY,
    code text UNIQUE NOT NULL,
    zone text NOT NULL
);

INSERT INTO bins (code, zone) VALUES
    ('A-01', 'Zone A'),
    ('A-02', 'Zone A'),
    ('B-01', 'Zone B'),
    ('B-02', 'Zone B'),
    ('C-01', 'Cold Store');

CREATE TABLE stock_movements (
    id         bigserial PRIMARY KEY,
    part_id    uuid NOT NULL REFERENCES parts(id) ON DELETE CASCADE,
    change     int  NOT NULL,                 -- +receive / -issue
    reason     text NOT NULL,
    bin_id     int  REFERENCES bins(id),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_stock_mov_part ON stock_movements (part_id, created_at DESC);
