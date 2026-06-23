-- =============================================================================
-- Phase 5 — integration events (integration-service)
-- Inbound webhooks from external systems (e.g. an ERP) land here. Stub: stored
-- and acknowledged; downstream processing is out of scope for the demo.
-- =============================================================================

CREATE TABLE integration_events (
    id          bigserial PRIMARY KEY,
    source      text NOT NULL,
    event_type  text,
    payload     jsonb NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_integration_received ON integration_events (received_at DESC);
