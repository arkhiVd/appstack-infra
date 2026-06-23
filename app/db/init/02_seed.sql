-- =============================================================================
-- Synthetic seed : 10 categories + 500 MRO parts
-- Admin user is seeded by auth-service on startup (needs bcrypt hashing).
-- =============================================================================

INSERT INTO categories (name, slug) VALUES
    ('Bearings',   'bearings'),
    ('Filters',    'filters'),
    ('Seals',      'seals'),
    ('Belts',      'belts'),
    ('Gaskets',    'gaskets'),
    ('Fasteners',  'fasteners'),
    ('Valves',     'valves'),
    ('Lubricants', 'lubricants'),
    ('Electrical', 'electrical'),
    ('Hydraulics', 'hydraulics');

-- 500 parts spread evenly across the 10 categories (ids 1..10).
INSERT INTO parts (part_number, name, description, category_id, unit_price, uom, stock_qty)
SELECT
    'MRO-' || LPAD(g::text, 5, '0'),
    cat.name || ' '
        || (ARRAY['Standard','Heavy-Duty','Industrial','Precision',
                  'High-Temp','Compact','Sealed','Reinforced'])[1 + (g % 8)]
        || ' Type ' || (g % 50),
    'Synthetic catalog item in the ' || cat.name || ' category.',
    cat.id,
    round((random() * 490 + 10)::numeric, 2),
    (ARRAY['EA','BOX','SET','PKG'])[1 + (g % 4)],
    (random() * 200)::int
FROM generate_series(1, 500) AS g
JOIN categories cat ON cat.id = 1 + (g % 10);
