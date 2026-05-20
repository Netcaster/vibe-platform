-- ═══════════════════════════════════════════════════════════════
-- VIBE Platform — Full Database Schema
-- Multi-tenant White-Label Video SaaS
-- ═══════════════════════════════════════════════════════════════

-- Enable UUID support
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ──────────────────────────────────────────────────────────────
-- 1. TENANTS
-- Each creator or training business gets one tenant record.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE tenants (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name                VARCHAR(255) NOT NULL,
  slug                VARCHAR(100) NOT NULL UNIQUE,         -- URL-safe identifier
  status              VARCHAR(30)  NOT NULL DEFAULT 'pending',
                                                             -- pending | active | suspended | archived
  -- Branding
  logo_url            TEXT,
  favicon_url         TEXT,
  primary_color       VARCHAR(20)  DEFAULT '#088395',
  accent_color        VARCHAR(20)  DEFAULT '#05bfdb',
  custom_domain       VARCHAR(255) UNIQUE,                  -- e.g. learn.creatorname.com
  tagline             TEXT,

  -- Stripe Connect
  stripe_account_id   VARCHAR(100),                        -- Stripe Express account ID
  stripe_onboarded    BOOLEAN      DEFAULT FALSE,
  platform_fee_pct    NUMERIC(5,2) DEFAULT 10.00,          -- % taken by platform

  -- Settings (JSON)
  settings            JSONB        DEFAULT '{}',

  created_at          TIMESTAMPTZ  DEFAULT NOW(),
  updated_at          TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX idx_tenants_slug  ON tenants(slug);
CREATE INDEX idx_tenants_status ON tenants(status);


-- ──────────────────────────────────────────────────────────────
-- 2. USERS
-- Global user table — one account works across all tenants.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE users (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name                VARCHAR(255) NOT NULL,
  email               VARCHAR(320) NOT NULL UNIQUE,
  email_verified      BOOLEAN      DEFAULT FALSE,

  -- Auth
  auth_provider       VARCHAR(30)  DEFAULT 'email',        -- email | google | apple
  auth_provider_id    VARCHAR(255),
  password_hash       TEXT,                                 -- null if social login

  -- Profile
  avatar_url          TEXT,
  bio                 TEXT,
  status              VARCHAR(30)  NOT NULL DEFAULT 'active',
                                                             -- active | suspended | deleted

  last_login_at       TIMESTAMPTZ,
  created_at          TIMESTAMPTZ  DEFAULT NOW(),
  updated_at          TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX idx_users_email    ON users(email);
CREATE INDEX idx_users_status   ON users(status);


-- ──────────────────────────────────────────────────────────────
-- 3. TENANT USERS
-- Joins users to tenants with a role (many-to-many + roles).
-- ──────────────────────────────────────────────────────────────
CREATE TABLE tenant_users (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES users(id)   ON DELETE CASCADE,
  role        VARCHAR(30) NOT NULL DEFAULT 'learner',
                                    -- owner | admin | instructor | staff | learner
  status      VARCHAR(30) NOT NULL DEFAULT 'active',
  joined_at   TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW(),

  UNIQUE (tenant_id, user_id)
);

CREATE INDEX idx_tenant_users_tenant ON tenant_users(tenant_id);
CREATE INDEX idx_tenant_users_user   ON tenant_users(user_id);
CREATE INDEX idx_tenant_users_role   ON tenant_users(role);


-- ──────────────────────────────────────────────────────────────
-- 4. COURSES
-- The sellable learning container owned by a tenant.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE courses (
  id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id            UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

  title                VARCHAR(500) NOT NULL,
  slug                 VARCHAR(200) NOT NULL,
  description          TEXT,
  short_description    TEXT,
  thumbnail_url        TEXT,
  preview_video_id     TEXT,                                -- free preview lesson provider ID

  -- Categorization
  category             VARCHAR(100),
  tags                 TEXT[],
  level                VARCHAR(30) DEFAULT 'beginner',      -- beginner | intermediate | advanced

  -- Certificate settings
  certificate_enabled  BOOLEAN     DEFAULT FALSE,
  cert_template_url    TEXT,

  -- Visibility
  visibility           VARCHAR(30) NOT NULL DEFAULT 'private',
                                                             -- private | unlisted | public
  featured             BOOLEAN     DEFAULT FALSE,

  -- Stats (denormalized for performance)
  lesson_count         INT         DEFAULT 0,
  total_duration_sec   INT         DEFAULT 0,
  enrolled_count       INT         DEFAULT 0,

  status               VARCHAR(30) NOT NULL DEFAULT 'draft',
                                                             -- draft | published | archived
  published_at         TIMESTAMPTZ,
  created_at           TIMESTAMPTZ DEFAULT NOW(),
  updated_at           TIMESTAMPTZ DEFAULT NOW(),

  UNIQUE (tenant_id, slug)
);

CREATE INDEX idx_courses_tenant   ON courses(tenant_id);
CREATE INDEX idx_courses_status   ON courses(status);
CREATE INDEX idx_courses_visibility ON courses(visibility);


-- ──────────────────────────────────────────────────────────────
-- 5. LESSONS
-- Individual content units within a course.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE lessons (
  id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  course_id               UUID NOT NULL REFERENCES courses(id) ON DELETE CASCADE,

  title                   VARCHAR(500) NOT NULL,
  description             TEXT,
  lesson_order            INT NOT NULL DEFAULT 0,

  -- Content type
  content_type            VARCHAR(30) NOT NULL DEFAULT 'video',
                                                               -- video | live | document | quiz | text
  -- Streaming provider reference
  provider_name           VARCHAR(50),                        -- mux | vimeo | brightcove | jwplayer
  provider_video_id       TEXT,                               -- external ID in provider system
  provider_asset_id       TEXT,                               -- additional provider asset ref

  -- Metadata
  thumbnail_url           TEXT,
  duration_seconds        INT DEFAULT 0,
  transcript_url          TEXT,
  captions_url            TEXT,
  attachments             JSONB DEFAULT '[]',                 -- [{name, url, size}]

  -- Completion rule
  required_for_completion BOOLEAN DEFAULT TRUE,

  -- Access
  is_preview              BOOLEAN DEFAULT FALSE,             -- free preview without purchase
  status                  VARCHAR(30) NOT NULL DEFAULT 'draft',
                                                              -- draft | published | archived

  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_lessons_course ON lessons(course_id);
CREATE INDEX idx_lessons_order  ON lessons(course_id, lesson_order);


-- ──────────────────────────────────────────────────────────────
-- 6. PLANS
-- Defines a product/offer that a tenant can sell.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE plans (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id         UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

  name              VARCHAR(255) NOT NULL,
  description       TEXT,

  -- Billing
  billing_type      VARCHAR(30) NOT NULL DEFAULT 'subscription',
                                          -- subscription | one_time | rental
  price             NUMERIC(12,2) NOT NULL DEFAULT 0,
  currency          VARCHAR(10) NOT NULL DEFAULT 'USD',
  interval          VARCHAR(20),          -- monthly | yearly | null for one-time/rental
  trial_days        INT DEFAULT 0,

  -- Access scope
  access_scope      VARCHAR(30) NOT NULL DEFAULT 'course',
                                          -- library | course | rental
  rental_hours      INT,                 -- for rental type: how many hours access lasts

  -- Stripe
  stripe_price_id   TEXT,               -- Stripe Price ID
  stripe_product_id TEXT,               -- Stripe Product ID

  -- Display
  is_featured       BOOLEAN DEFAULT FALSE,
  sort_order        INT DEFAULT 0,
  status            VARCHAR(30) NOT NULL DEFAULT 'active',
                                          -- active | archived

  created_at        TIMESTAMPTZ DEFAULT NOW(),
  updated_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_plans_tenant ON plans(tenant_id);
CREATE INDEX idx_plans_status ON plans(status);


-- ──────────────────────────────────────────────────────────────
-- 7. PLAN COURSE MAPPINGS
-- Many-to-many: which courses a plan unlocks.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE plan_courses (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  plan_id     UUID NOT NULL REFERENCES plans(id)   ON DELETE CASCADE,
  course_id   UUID NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ DEFAULT NOW(),

  UNIQUE (plan_id, course_id)
);

CREATE INDEX idx_plan_courses_plan   ON plan_courses(plan_id);
CREATE INDEX idx_plan_courses_course ON plan_courses(course_id);


-- ──────────────────────────────────────────────────────────────
-- 8. SUBSCRIPTIONS
-- Active billing relationship between a user and a tenant plan.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE subscriptions (
  id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id                 UUID NOT NULL REFERENCES users(id)    ON DELETE RESTRICT,
  tenant_id               UUID NOT NULL REFERENCES tenants(id)  ON DELETE RESTRICT,
  plan_id                 UUID NOT NULL REFERENCES plans(id)    ON DELETE RESTRICT,

  -- Stripe
  stripe_subscription_id  TEXT UNIQUE,
  stripe_customer_id      TEXT,

  -- Status
  status                  VARCHAR(30) NOT NULL DEFAULT 'active',
                                               -- trialing | active | past_due | canceled | paused | incomplete
  -- Timing
  trial_end_at            TIMESTAMPTZ,
  current_period_start    TIMESTAMPTZ,
  current_period_end      TIMESTAMPTZ,
  canceled_at             TIMESTAMPTZ,
  cancel_at_period_end    BOOLEAN DEFAULT FALSE,

  started_at              TIMESTAMPTZ DEFAULT NOW(),
  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_subscriptions_user   ON subscriptions(user_id);
CREATE INDEX idx_subscriptions_tenant ON subscriptions(tenant_id);
CREATE INDEX idx_subscriptions_plan   ON subscriptions(plan_id);
CREATE INDEX idx_subscriptions_status ON subscriptions(status);


-- ──────────────────────────────────────────────────────────────
-- 9. TRANSACTIONS
-- Immutable record of every payment event.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE transactions (
  id                        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id                   UUID NOT NULL REFERENCES users(id)    ON DELETE RESTRICT,
  tenant_id                 UUID NOT NULL REFERENCES tenants(id)  ON DELETE RESTRICT,
  plan_id                   UUID          REFERENCES plans(id)    ON DELETE SET NULL,
  subscription_id           UUID          REFERENCES subscriptions(id) ON DELETE SET NULL,

  -- Money
  amount                    NUMERIC(12,2) NOT NULL,
  currency                  VARCHAR(10)   NOT NULL DEFAULT 'USD',
  platform_fee              NUMERIC(12,2) DEFAULT 0,  -- fee retained by platform
  creator_amount            NUMERIC(12,2) DEFAULT 0,  -- amount to creator

  payment_type              VARCHAR(30)   NOT NULL,   -- subscription | one_time | rental | refund
  provider                  VARCHAR(30)   NOT NULL DEFAULT 'stripe',

  -- Stripe references
  stripe_payment_intent_id  TEXT,
  stripe_invoice_id         TEXT,
  stripe_charge_id          TEXT,
  stripe_transfer_id        TEXT,                    -- transfer to creator account

  status                    VARCHAR(30)   NOT NULL DEFAULT 'pending',
                                                      -- pending | succeeded | failed | refunded | disputed

  metadata                  JSONB DEFAULT '{}',
  created_at                TIMESTAMPTZ   DEFAULT NOW(),
  updated_at                TIMESTAMPTZ   DEFAULT NOW()
);

CREATE INDEX idx_transactions_user   ON transactions(user_id);
CREATE INDEX idx_transactions_tenant ON transactions(tenant_id);
CREATE INDEX idx_transactions_status ON transactions(status);
CREATE INDEX idx_transactions_created ON transactions(created_at DESC);


-- ──────────────────────────────────────────────────────────────
-- 10. ENTITLEMENTS
-- Controls what content a user may access and when it expires.
-- This is the gatekeeper — checked at every playback request.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE entitlements (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  tenant_id       UUID NOT NULL REFERENCES tenants(id)  ON DELETE CASCADE,
  plan_id         UUID          REFERENCES plans(id)    ON DELETE SET NULL,

  -- Source of this entitlement
  source_type     VARCHAR(30) NOT NULL,               -- subscription | one_time | rental | admin_grant | promo
  source_id       UUID,                               -- ID of subscription, transaction, etc.

  -- Access scope
  access_scope    VARCHAR(30) NOT NULL DEFAULT 'course', -- library | course | lesson | rental

  -- Timing
  starts_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ends_at         TIMESTAMPTZ,                        -- NULL = never expires (lifetime)

  status          VARCHAR(30) NOT NULL DEFAULT 'active',
                                       -- active | expired | revoked | paused

  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_entitlements_user          ON entitlements(user_id);
CREATE INDEX idx_entitlements_tenant        ON entitlements(tenant_id);
CREATE INDEX idx_entitlements_plan          ON entitlements(plan_id);
CREATE INDEX idx_entitlements_status        ON entitlements(status);
CREATE INDEX idx_entitlements_ends_at       ON entitlements(ends_at);
-- Composite index for the playback check (user + tenant + status + expiry)
CREATE INDEX idx_entitlements_access_check  ON entitlements(user_id, tenant_id, status, ends_at);


-- ──────────────────────────────────────────────────────────────
-- 11. LESSON COMPLETIONS
-- One row per user per lesson when they finish it (yes/no MVP).
-- Used to calculate eligibility for certificates.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE lesson_completions (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  lesson_id       UUID NOT NULL REFERENCES lessons(id)  ON DELETE CASCADE,
  course_id       UUID NOT NULL REFERENCES courses(id)  ON DELETE CASCADE,

  completed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  watch_verified  BOOLEAN DEFAULT TRUE,               -- system-verified (not self-reported)

  -- Optional enrichment (for future phases)
  watch_pct       NUMERIC(5,2) DEFAULT 100,           -- percent watched at completion
  metadata        JSONB DEFAULT '{}',

  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW(),

  UNIQUE (user_id, lesson_id)
);

CREATE INDEX idx_lesson_completions_user   ON lesson_completions(user_id);
CREATE INDEX idx_lesson_completions_lesson ON lesson_completions(lesson_id);
CREATE INDEX idx_lesson_completions_course ON lesson_completions(user_id, course_id);


-- ──────────────────────────────────────────────────────────────
-- 12. CERTIFICATES
-- Tracks eligibility, approval, and issuance per user per course.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE certificates (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  tenant_id       UUID NOT NULL REFERENCES tenants(id)  ON DELETE CASCADE,
  course_id       UUID NOT NULL REFERENCES courses(id)  ON DELETE CASCADE,

  -- Status flow: not_started → eligible → approved → issued
  status          VARCHAR(30) NOT NULL DEFAULT 'not_started',

  -- Admin approval
  approved_by     UUID REFERENCES users(id) ON DELETE SET NULL,
  approved_at     TIMESTAMPTZ,
  approval_note   TEXT,

  -- Issuance
  issued_at       TIMESTAMPTZ,
  certificate_url TEXT,                               -- PDF or hosted asset URL
  certificate_uid VARCHAR(100) UNIQUE,               -- human-readable cert ID (e.g. VIBE-2026-00001)

  -- Audit
  eligible_at     TIMESTAMPTZ,                       -- when system detected all lessons complete
  requested_at    TIMESTAMPTZ,                       -- when user clicked "Request Certificate"

  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW(),

  UNIQUE (user_id, course_id)
);

CREATE INDEX idx_certificates_user   ON certificates(user_id);
CREATE INDEX idx_certificates_tenant ON certificates(tenant_id);
CREATE INDEX idx_certificates_course ON certificates(course_id);
CREATE INDEX idx_certificates_status ON certificates(status);


-- ──────────────────────────────────────────────────────────────
-- 13. PLAYBACK TOKENS (optional for Phase 2)
-- Short-lived secure tokens for video playback requests.
-- Prevents raw video URL reuse/sharing.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE playback_tokens (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID NOT NULL REFERENCES users(id)   ON DELETE CASCADE,
  lesson_id       UUID NOT NULL REFERENCES lessons(id) ON DELETE CASCADE,
  entitlement_id  UUID NOT NULL REFERENCES entitlements(id) ON DELETE CASCADE,

  token           VARCHAR(255) NOT NULL UNIQUE DEFAULT encode(gen_random_bytes(32), 'hex'),
  provider_name   VARCHAR(50),
  provider_video_id TEXT,

  expires_at      TIMESTAMPTZ NOT NULL,              -- short TTL (e.g. 4 hours)
  used_at         TIMESTAMPTZ,
  revoked         BOOLEAN DEFAULT FALSE,

  created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_playback_tokens_token    ON playback_tokens(token);
CREATE INDEX idx_playback_tokens_user     ON playback_tokens(user_id);
CREATE INDEX idx_playback_tokens_expires  ON playback_tokens(expires_at);


-- ──────────────────────────────────────────────────────────────
-- 14. WATCH HISTORY (Phase 2)
-- Track what users are watching for continue watching feature.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE watch_history (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  lesson_id       UUID NOT NULL REFERENCES lessons(id)  ON DELETE CASCADE,
  course_id       UUID NOT NULL REFERENCES courses(id)  ON DELETE CASCADE,

  position_sec    INT DEFAULT 0,                     -- resume position in seconds
  watch_pct       NUMERIC(5,2) DEFAULT 0,
  session_count   INT DEFAULT 1,

  last_watched_at TIMESTAMPTZ DEFAULT NOW(),
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW(),

  UNIQUE (user_id, lesson_id)
);

CREATE INDEX idx_watch_history_user   ON watch_history(user_id);
CREATE INDEX idx_watch_history_last   ON watch_history(user_id, last_watched_at DESC);


-- ──────────────────────────────────────────────────────────────
-- 15. ANALYTICS EVENTS (Phase 2)
-- Raw event stream for platform analytics.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE analytics_events (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id   UUID REFERENCES tenants(id) ON DELETE SET NULL,
  user_id     UUID REFERENCES users(id)   ON DELETE SET NULL,

  event_type  VARCHAR(100) NOT NULL,  -- video.play | video.complete | course.enroll | etc.
  resource_type VARCHAR(50),          -- lesson | course | plan | etc.
  resource_id UUID,

  properties  JSONB DEFAULT '{}',
  ip_address  INET,
  user_agent  TEXT,
  referrer    TEXT,

  created_at  TIMESTAMPTZ DEFAULT NOW()
) PARTITION BY RANGE (created_at);

-- Create initial partition
CREATE TABLE analytics_events_2026 PARTITION OF analytics_events
  FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');

CREATE INDEX idx_analytics_tenant  ON analytics_events(tenant_id, created_at DESC);
CREATE INDEX idx_analytics_user    ON analytics_events(user_id, created_at DESC);
CREATE INDEX idx_analytics_type    ON analytics_events(event_type, created_at DESC);


-- ──────────────────────────────────────────────────────────────
-- 16. COUPONS (Phase 2)
-- Discount codes for promotions.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE coupons (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  code            VARCHAR(50) NOT NULL,

  discount_type   VARCHAR(20) NOT NULL DEFAULT 'percent', -- percent | fixed
  discount_value  NUMERIC(10,2) NOT NULL,
  max_uses        INT,
  uses_count      INT DEFAULT 0,
  applies_to      VARCHAR(30) DEFAULT 'any',  -- any | plan_id list

  expires_at      TIMESTAMPTZ,
  status          VARCHAR(20) DEFAULT 'active',

  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW(),

  UNIQUE (tenant_id, code)
);


-- ──────────────────────────────────────────────────────────────
-- AUTO-UPDATE updated_at TRIGGER
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to all tables with updated_at
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'tenants','users','tenant_users','courses','lessons',
    'plans','subscriptions','transactions','entitlements',
    'lesson_completions','certificates','watch_history','coupons'
  ] LOOP
    EXECUTE format('
      CREATE TRIGGER trg_updated_at_%s
      BEFORE UPDATE ON %s
      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
    ', t, t);
  END LOOP;
END;
$$;


-- ──────────────────────────────────────────────────────────────
-- CERTIFICATE AUTO-ELIGIBILITY TRIGGER
-- When a lesson_completion row is inserted, check if all required
-- lessons for the course are done. If yes, mark certificate eligible.
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION check_certificate_eligibility()
RETURNS TRIGGER AS $$
DECLARE
  total_required    INT;
  completed_required INT;
  cert_enabled      BOOLEAN;
BEGIN
  -- How many required lessons in this course?
  SELECT COUNT(*) INTO total_required
  FROM lessons
  WHERE course_id = NEW.course_id
    AND required_for_completion = TRUE
    AND status = 'published';

  -- How many has this user completed?
  SELECT COUNT(*) INTO completed_required
  FROM lesson_completions lc
  JOIN lessons l ON l.id = lc.lesson_id
  WHERE lc.user_id = NEW.user_id
    AND lc.course_id = NEW.course_id
    AND l.required_for_completion = TRUE;

  -- Check if course has certificates enabled
  SELECT certificate_enabled INTO cert_enabled
  FROM courses WHERE id = NEW.course_id;

  -- If all required lessons complete and certificates are on → mark eligible
  IF cert_enabled AND total_required > 0 AND completed_required >= total_required THEN
    INSERT INTO certificates (user_id, tenant_id, course_id, status, eligible_at)
    SELECT NEW.user_id, c.tenant_id, NEW.course_id, 'eligible', NOW()
    FROM courses c WHERE c.id = NEW.course_id
    ON CONFLICT (user_id, course_id)
    DO UPDATE SET status = 'eligible', eligible_at = NOW(), updated_at = NOW()
    WHERE certificates.status = 'not_started';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_certificate_eligibility
AFTER INSERT ON lesson_completions
FOR EACH ROW EXECUTE FUNCTION check_certificate_eligibility();


-- ──────────────────────────────────────────────────────────────
-- HELPFUL VIEWS
-- ──────────────────────────────────────────────────────────────

-- Course progress per user
CREATE VIEW v_course_progress AS
SELECT
  lc.user_id,
  lc.course_id,
  c.tenant_id,
  COUNT(DISTINCT lc.lesson_id) AS completed_lessons,
  COUNT(DISTINCT l.id) FILTER (WHERE l.required_for_completion) AS required_lessons,
  ROUND(
    COUNT(DISTINCT lc.lesson_id)::NUMERIC
    / NULLIF(COUNT(DISTINCT l.id) FILTER (WHERE l.required_for_completion), 0) * 100, 1
  ) AS progress_pct
FROM lesson_completions lc
JOIN courses c ON c.id = lc.course_id
JOIN lessons l ON l.course_id = lc.course_id AND l.status = 'published'
GROUP BY lc.user_id, lc.course_id, c.tenant_id;

-- Active entitlements with plan and tenant info
CREATE VIEW v_active_entitlements AS
SELECT
  e.*,
  p.name        AS plan_name,
  p.access_scope,
  p.billing_type,
  t.name        AS tenant_name,
  t.slug        AS tenant_slug
FROM entitlements e
JOIN plans   p ON p.id = e.plan_id
JOIN tenants t ON t.id = e.tenant_id
WHERE e.status = 'active'
  AND (e.ends_at IS NULL OR e.ends_at > NOW());

-- Revenue summary per tenant
CREATE VIEW v_tenant_revenue AS
SELECT
  tenant_id,
  DATE_TRUNC('month', created_at) AS month,
  COUNT(*)              AS transaction_count,
  SUM(amount)           AS gross_revenue,
  SUM(platform_fee)     AS platform_fee,
  SUM(creator_amount)   AS creator_revenue
FROM transactions
WHERE status = 'succeeded'
GROUP BY tenant_id, DATE_TRUNC('month', created_at);


-- ──────────────────────────────────────────────────────────────
-- SEED: Platform default tenant (for testing)
-- ──────────────────────────────────────────────────────────────
INSERT INTO tenants (name, slug, status, primary_color, accent_color)
VALUES ('VIBE Demo', 'vibe-demo', 'active', '#088395', '#05bfdb');

-- ═══════════════════════════════════════════════════════════════
-- END OF SCHEMA
-- Tables: tenants, users, tenant_users, courses, lessons,
--         plans, plan_courses, subscriptions, transactions,
--         entitlements, lesson_completions, certificates,
--         playback_tokens, watch_history, analytics_events,
--         coupons
-- Views: v_course_progress, v_active_entitlements, v_tenant_revenue
-- Triggers: set_updated_at (all tables), certificate eligibility
-- ═══════════════════════════════════════════════════════════════
