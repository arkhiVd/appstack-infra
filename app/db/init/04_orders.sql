-- =============================================================================
-- Phase 4 — requisitions (orders-service)
-- Staff raise a requisition (basket of parts + qty). An admin approves it, which
-- atomically deducts stock via the shared stock_movements ledger. Approval fails
-- (rolls back) if any line has insufficient stock.
-- =============================================================================

CREATE TABLE requisitions (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    requested_by text NOT NULL DEFAULT 'staff',
    status       text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','approved','rejected')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    decided_at   timestamptz
);

CREATE TABLE requisition_items (
    id             bigserial PRIMARY KEY,
    requisition_id uuid NOT NULL REFERENCES requisitions(id) ON DELETE CASCADE,
    part_id        uuid NOT NULL REFERENCES parts(id),
    qty            int  NOT NULL CHECK (qty > 0)
);

CREATE INDEX idx_req_items_req ON requisition_items (requisition_id);
