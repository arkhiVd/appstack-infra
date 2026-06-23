-- =============================================================================
-- Phase 4 — notifications (notification-service)
-- Append-only log of alerts. The low-stock monitor writes 'low_stock' rows; in a
-- real system these would also fan out to email/Slack (stubbed to a log line).
-- =============================================================================

CREATE TABLE notifications (
    id         bigserial PRIMARY KEY,
    kind       text NOT NULL,
    part_id    uuid,
    message    text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_notif_part_kind ON notifications (part_id, kind, created_at DESC);
