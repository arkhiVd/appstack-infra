-- =============================================================================
-- Phase 5 — suppliers (suppliers-service)
-- Vendor master data: who we buy parts from, with lead times for reordering.
-- =============================================================================

CREATE TABLE suppliers (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code          text UNIQUE NOT NULL,
    name          text NOT NULL,
    contact_email text,
    phone         text,
    lead_time_days int NOT NULL DEFAULT 7,
    created_at    timestamptz NOT NULL DEFAULT now()
);

INSERT INTO suppliers (code, name, contact_email, phone, lead_time_days) VALUES
    ('SUP-ACME',  'Acme Industrial Supplies', 'sales@acme.example',       '+91-22-1000', 5),
    ('SUP-BOLT',  'BoltCo Fasteners',         'orders@boltco.example',    '+91-22-2000', 10),
    ('SUP-HYDRO', 'HydroParts Ltd',           'info@hydroparts.example',  '+91-22-3000', 14);
