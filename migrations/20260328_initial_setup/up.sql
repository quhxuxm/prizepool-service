-- =========================================================
-- Network Jackpots (White Paper) - PostgreSQL DDL (single schema)
-- Source: [NJ White Paper Clarifications to Compliance Feebdack 1.7.pdf](https://igtplc-my.sharepoint.com/personal/hao_qu_igt_com/Documents/Microsoft%20Copilot%20Chat%20%E6%96%87%E4%BB%B6/NJ%20White%20Paper%20Clarifications%20to%20Compliance%20Feebdack%201.7.pdf?EntityRepresentationId=cc3dc69e-f081-475f-8e50-3aedcd24704c)
-- =========================================================

-- Optional: crypto for ids/hashes if needed later
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =========================================================
-- 1) Metadata tables: Licensee / Operator / Game (Req: 5, 9, 12, 14)
-- =========================================================
CREATE TABLE IF NOT EXISTS nj_licensee
(
    licensee_id TEXT PRIMARY KEY,
    name        TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS nj_operator
(
    operator_id TEXT PRIMARY KEY,
    licensee_id TEXT        NOT NULL REFERENCES nj_licensee (licensee_id),
    name        TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- White Paper game selection dimensions: provider, type, name, base RTP, skin/variation
CREATE TABLE IF NOT EXISTS nj_game
(
    game_id    TEXT PRIMARY KEY,
    provider   TEXT        NOT NULL,
    game_type  TEXT        NOT NULL,
    name       TEXT        NOT NULL,
    base_rtp   NUMERIC(6, 4),
    skin_id    TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE nj_game IS 'Req: 9 Game Selection: store provider/type/name/base RTP/skin variation for selection & attachment.';

-- =========================================================
-- 2) Group (Promotion) configuration (Req: 12.1 Hierarchy)
-- =========================================================
CREATE TABLE IF NOT EXISTS nj_group
(
    group_id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name                   TEXT        NOT NULL UNIQUE,                     -- unique name enforced (12.1a)
    description            TEXT,
    base_currency          CHAR(3)     NOT NULL,                            -- 12.1c, 11
    exchange_rate_schedule TEXT        NOT NULL CHECK (exchange_rate_schedule IN
                                                       ('DAILY',
                                                        'FIRST_DAY_WEEK',
                                                        'LAST_DAY_WEEK',
                                                        'FIRST_DAY_MONTH',
                                                        'LAST_DAY_MONTH')), -- 12.1d, 11.1
    funding_scheme         TEXT        NOT NULL CHECK (funding_scheme IN
                                                       ('ZERO_LIABILITY',
                                                        'FIXED_FUND')),     -- 12.1e, 8.1
    status                 TEXT        NOT NULL CHECK (status IN
                                                       ('DRAFT', 'ACTIVE',
                                                        'SUSPENDED',
                                                        'TERMINATED')),     -- 14 status filter
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE nj_group IS 'Req: 12.1 Group top-level config (a~n): base currency, FX schedule, funding scheme, audience, games+JP%, schedule, widget config.';

-- Group deployed to licensee/operator(s) (12.1f, 12.6)
CREATE TABLE IF NOT EXISTS nj_group_operator
(
    group_id    BIGINT NOT NULL REFERENCES nj_group (group_id) ON DELETE CASCADE,
    licensee_id TEXT   NOT NULL REFERENCES nj_licensee (licensee_id),
    operator_id TEXT   NOT NULL REFERENCES nj_operator (operator_id),
    PRIMARY KEY (group_id, operator_id)
);

COMMENT ON TABLE nj_group_operator IS 'Req: 12.1f + 12.6 CrossLID: where group is deployed (licensee/operator).';

-- Audience include/exclude + opt-in + T&C (12.1g, 10.2)
CREATE TABLE IF NOT EXISTS nj_group_audience_rule
(
    group_id         BIGINT PRIMARY KEY REFERENCES nj_group (group_id) ON DELETE CASCADE,
    include_list_ref TEXT,
    exclude_list_ref TEXT,
    opt_in_required  BOOLEAN NOT NULL DEFAULT FALSE,
    tnc_link         TEXT
);

COMMENT ON TABLE nj_group_audience_rule IS 'Req: 12.1g + 10.2: audience restrictions; include/exclude and opt-in/T&C references (managed via Overlay/GT).';

-- Group games + per-game contribution % JP% (12.1h/i, 8/9)
CREATE TABLE IF NOT EXISTS nj_group_game
(
    group_id BIGINT        NOT NULL REFERENCES nj_group (group_id) ON DELETE CASCADE,
    game_id  TEXT          NOT NULL REFERENCES nj_game (game_id),
    jp_pct   NUMERIC(9, 8) NOT NULL CHECK (jp_pct >= 0 AND jp_pct <= 1),
    PRIMARY KEY (group_id, game_id)
);

COMMENT ON TABLE nj_group_game IS 'Req: 12.1h/i + 9: attach games and per-game contribution% (JP%).';

-- Schedule: when each level is active and for what duration (12.1j, 14 days remaining)
CREATE TABLE IF NOT EXISTS nj_level_schedule
(
    schedule_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    group_id    BIGINT      NOT NULL REFERENCES nj_group (group_id) ON DELETE CASCADE,
    level_no    INT         NOT NULL,
    start_at    TIMESTAMPTZ NOT NULL,
    end_at      TIMESTAMPTZ NOT NULL,
    timezone    TEXT        NOT NULL DEFAULT 'UTC',
    CHECK (end_at > start_at)
);

COMMENT ON TABLE nj_level_schedule IS 'Req: 12.1j + 14: schedule per level (activation window/duration) used for dashboard days remaining.';
CREATE INDEX IF NOT EXISTS ix_nj_level_schedule_group ON nj_level_schedule (group_id, level_no, start_at);

-- =========================================================
-- 3) Level configuration (Req: 12.1 Level a~m)
-- =========================================================
CREATE TABLE IF NOT EXISTS nj_level
(
    level_id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    group_id               BIGINT          NOT NULL REFERENCES nj_group (group_id) ON DELETE CASCADE,
    level_no               INT             NOT NULL,
    level_name             TEXT            NOT NULL,

    -- Level contribution% (sum of all levels = 100%) - 12.1(2)(b)
    level_contrib_pct      NUMERIC(9, 8)   NOT NULL CHECK (level_contrib_pct > 0 AND level_contrib_pct <= 1),

    -- Network Type: single-site vs multi-site pools (12.1(2)(c))
    network_type           TEXT            NOT NULL CHECK (network_type IN ('SINGLE_SITE', 'MULTI_SITE')),

    -- Trigger type per level (12.1(2)(d), 13)
    trigger_type           TEXT            NOT NULL CHECK (trigger_type IN
                                                           ('FIXED_ODDS',
                                                            'MYSTERY_BOUNDARY',
                                                            'TIMER_COUNTDOWN',
                                                            'MULTIDROP')),

    -- Funding Risk Profile per level (12.1(2)(e), 8.5)
    risk_profile_id        BIGINT          NOT NULL,

    -- Start/End values (12.1(2)(f)(g))
    start_value            NUMERIC(20, 10) NOT NULL CHECK (start_value >= 0),
    end_value              NUMERIC(20, 10),

    -- Seed# / No of Seeds (12.1(2)(h), 8.7)
    seed_no                INT             NOT NULL DEFAULT 1 CHECK (seed_no >= 1),

    -- Block Win Until Funded (12.1(2)(i), 8.8)
    block_win_until_funded BOOLEAN         NOT NULL DEFAULT FALSE,

    -- Auto restart / auto pay (12.1(2)(j)(k), 13)
    auto_restart           BOOLEAN         NOT NULL DEFAULT TRUE,
    auto_pay_win           BOOLEAN         NOT NULL DEFAULT TRUE,

    -- Bet size / prize order (12.1(2)(l)(m))
    bet_size_threshold     NUMERIC(20, 10),
    prize_order            TEXT,

    UNIQUE (group_id, level_no)
);

COMMENT ON TABLE nj_level IS 'Req: 12.1 Level(a~m): contribution%, network type, trigger type, risk profile, start/end, seed#, block win until funded, auto restart, auto pay, bet size, prize order.';
CREATE INDEX IF NOT EXISTS ix_nj_level_group ON nj_level (group_id);

-- =========================================================
-- 4) Funding Risk Profiles (Req: 8.5) + 5 thresholds
-- =========================================================
CREATE TABLE IF NOT EXISTS nj_funding_risk_profile
(
    risk_profile_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            TEXT        NOT NULL UNIQUE CHECK (name IN ('VERY_LOW', 'LOW', 'MEDIUM', 'HIGH')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE nj_funding_risk_profile IS 'Req: 8.5 Funding Risk Profiles - Very Low/Low/Medium/High.';

-- Exactly 5 thresholds per profile (8.5)
CREATE TABLE IF NOT EXISTS nj_risk_profile_threshold
(
    risk_profile_id   BIGINT        NOT NULL REFERENCES nj_funding_risk_profile (risk_profile_id) ON DELETE CASCADE,
    threshold_no      SMALLINT      NOT NULL CHECK (threshold_no BETWEEN 1 AND 5),
    seed_progress_pct NUMERIC(6, 5) NOT NULL CHECK (seed_progress_pct > 0 AND seed_progress_pct <= 1),
    seed_split_pct    NUMERIC(6, 5) NOT NULL CHECK (seed_split_pct >= 0 AND seed_split_pct <= 1),
    PRIMARY KEY (risk_profile_id, threshold_no)
);

COMMENT ON TABLE nj_risk_profile_threshold IS 'Req: 8.5 five threshold values; reaching threshold updates seed/prize split; once seed >= start/restart then 100% to prize.';
CREATE INDEX IF NOT EXISTS ix_nj_rp_threshold_progress ON nj_risk_profile_threshold (risk_profile_id, seed_progress_pct);

-- bind level.risk_profile_id to profile table
ALTER TABLE nj_level
    ADD CONSTRAINT fk_level_risk_profile
        FOREIGN KEY (risk_profile_id) REFERENCES nj_funding_risk_profile (risk_profile_id);

-- =========================================================
-- 5) Fixed Fund budget (Req: 8.3) - Group level
-- =========================================================
CREATE TABLE IF NOT EXISTS nj_fixed_fund_budget
(
    group_id         BIGINT PRIMARY KEY REFERENCES nj_group (group_id) ON DELETE CASCADE,
    budget_total     NUMERIC(20, 10) NOT NULL CHECK (budget_total >= 0),
    budget_remaining NUMERIC(20, 10) NOT NULL CHECK (budget_remaining >= 0),
    updated_at       TIMESTAMPTZ     NOT NULL DEFAULT now()
);

COMMENT ON TABLE nj_fixed_fund_budget IS 'Req: 8.3 Fixed Fund - overall cap; reduce budget each awarded prize; budget can be increased; insufficient -> group suspended.';

-- =========================================================
-- 6) Trigger configuration (Req: 13) + type-specific settings
-- =========================================================
CREATE TABLE IF NOT EXISTS nj_level_trigger
(
    level_id               BIGINT PRIMARY KEY REFERENCES nj_level (level_id) ON DELETE CASCADE,
    type                   TEXT    NOT NULL CHECK (type IN ('FIXED_ODDS',
                                                            'MYSTERY_BOUNDARY',
                                                            'TIMER_COUNTDOWN',
                                                            'MULTIDROP')),
    block_win_until_funded BOOLEAN NOT NULL DEFAULT FALSE,
    auto_pay_win           BOOLEAN NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE nj_level_trigger IS 'Req: 13 - triggers determine winning player; multiple trigger types in same group; all triggers support block win till funded & auto pay win.';

-- 13.1 Fixed Odds settings
CREATE TABLE IF NOT EXISTS nj_trigger_fixed_odds_settings
(
    level_id           BIGINT PRIMARY KEY REFERENCES nj_level (level_id) ON DELETE CASCADE,
    odds_1_in_x        BIGINT  NOT NULL CHECK (odds_1_in_x >= 1),
    bet_size_threshold NUMERIC(20, 10),
    linear_enabled     BOOLEAN NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE nj_trigger_fixed_odds_settings IS 'Req: 13.1 Fixed Odds Weighted - 1 in X per bet; optional bet size threshold with linear dynamics.';

-- 13.2 Mystery Boundary settings (start/end must-win-by-amount)
CREATE TABLE IF NOT EXISTS nj_trigger_mystery_boundary_settings
(
    level_id            BIGINT PRIMARY KEY REFERENCES nj_level (level_id) ON DELETE CASCADE,
    mystery_start_value NUMERIC(20, 10) NOT NULL CHECK (mystery_start_value >= 0),
    mystery_end_value   NUMERIC(20, 10) NOT NULL CHECK (mystery_end_value > mystery_start_value)
);

COMMENT ON TABLE nj_trigger_mystery_boundary_settings IS 'Req: 13.2 Mystery Boundary - win awarded between start and end; mystery win value per run (not exposed).';

-- 13.3 Timer Countdown settings
CREATE TABLE IF NOT EXISTS nj_trigger_timer_countdown_settings
(
    level_id              BIGINT PRIMARY KEY REFERENCES nj_level (level_id) ON DELETE CASCADE,
    win_time_sec          INT  NOT NULL CHECK (win_time_sec BETWEEN 0 AND 86400),
    granularity           TEXT NOT NULL CHECK (granularity IN ('SECOND', 'MINUTE')),
    max_intervals_per_day INT  NOT NULL CHECK (max_intervals_per_day > 0)
);

COMMENT ON TABLE nj_trigger_timer_countdown_settings IS 'Req: 13.3 Timer Countdown - time-based 1-in-X odds and win-by-time behavior.';

-- 13.4 Multidrop settings + drop prize table
CREATE TABLE IF NOT EXISTS nj_drop_prize_table
(
    drop_table_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    level_id           BIGINT NOT NULL UNIQUE REFERENCES nj_level (level_id) ON DELETE CASCADE,
    stage1_start_value NUMERIC(20, 10), -- minimum total prize amount (13.4)
    stage1_end_value   NUMERIC(20, 10),
    prize_order        TEXT             -- order rules described in 13.4
);

COMMENT ON TABLE nj_drop_prize_table IS 'Req: 13.4 Multidrop - stage 1 accumulation + stage 2 distribution; uses drop prize table tiers and odds.';

CREATE TABLE IF NOT EXISTS nj_drop_prize_table_item
(
    drop_table_id BIGINT          NOT NULL REFERENCES nj_drop_prize_table (drop_table_id) ON DELETE CASCADE,
    tier_no       INT             NOT NULL CHECK (tier_no >= 1),
    prize_type    TEXT            NOT NULL CHECK (prize_type IN
                                                  ('JACKPOT', 'FIXED_CASH',
                                                   'NON_CASH')),
    prize_value   NUMERIC(20, 10) NOT NULL CHECK (prize_value >= 0),
    odds_1_in_x   BIGINT          NOT NULL CHECK (odds_1_in_x >= 1),
    quantity      INT             NOT NULL DEFAULT 1 CHECK (quantity >= 1),
    PRIMARY KEY (drop_table_id, tier_no, prize_type, prize_value)
);

COMMENT ON TABLE nj_drop_prize_table_item IS 'Req: 13.4 + Figure 38: tiers with different 1-in-X odds, prize types and quantities; multiple prizes per run.';
CREATE INDEX IF NOT EXISTS ix_nj_drop_item ON nj_drop_prize_table_item (drop_table_id, tier_no);

-- =========================================================
-- 7) Widget / Notification configuration (Req: 10, 10.1, 12.1 k-n)
-- =========================================================
CREATE TABLE IF NOT EXISTS nj_level_widget_config
(
    level_id                BIGINT PRIMARY KEY REFERENCES nj_level (level_id) ON DELETE CASCADE,
    level_widget_skin_id    TEXT NOT NULL,                                  -- 12.1k
    win_celebration_skin_id TEXT NOT NULL,                                  -- 12.1l
    widget_duration_sec     INT  NOT NULL CHECK (widget_duration_sec >= 0), -- 12.1m
    close_to_win_param      TEXT                                            -- 12.1n (currency or time param)
);

COMMENT ON TABLE nj_level_widget_config IS 'Req: 10 + 12.1(k-n): per level widget skin, win celebration skin, widget duration, close-to-win parameter.';

CREATE TABLE IF NOT EXISTS nj_group_win_notification_config
(
    group_id             BIGINT PRIMARY KEY REFERENCES nj_group (group_id) ON DELETE CASCADE,
    enabled              BOOLEAN NOT NULL DEFAULT TRUE,
    display_duration_sec INT     NOT NULL DEFAULT 8 CHECK (display_duration_sec >= 0)
);

COMMENT ON TABLE nj_group_win_notification_config IS 'Req: 10.1 Win Notification Drawer - group-level enable/disable and display duration configurable.';

-- =========================================================
-- 8) Multi-currency FX (Req: 11, 11.1)
-- =========================================================
CREATE TABLE IF NOT EXISTS nj_exchange_rate
(
    from_ccy       CHAR(3)         NOT NULL,
    to_ccy         CHAR(3)         NOT NULL,
    rate           NUMERIC(20, 10) NOT NULL CHECK (rate > 0),
    effective_from TIMESTAMPTZ     NOT NULL,
    schedule_type  TEXT            NOT NULL CHECK (schedule_type IN
                                                   ('DAILY', 'FIRST_DAY_WEEK',
                                                    'LAST_DAY_WEEK',
                                                    'FIRST_DAY_MONTH',
                                                    'LAST_DAY_MONTH')),
    PRIMARY KEY (from_ccy, to_ccy, effective_from)
);

COMMENT ON TABLE nj_exchange_rate IS 'Req: 11/11.1 - FX rates used to convert bets to group base currency before contribution calc; wins base->player currency; schedule-based updates.';
CREATE INDEX IF NOT EXISTS ix_nj_fx_pair_time ON nj_exchange_rate (from_ccy, to_ccy, effective_from DESC);

-- =========================================================
-- 9) Runtime & Dashboard (Req: 14)
-- =========================================================
CREATE TABLE IF NOT EXISTS nj_group_runtime_state
(
    group_id        BIGINT PRIMARY KEY REFERENCES nj_group (group_id) ON DELETE CASCADE,
    environment     TEXT,
    status          TEXT        NOT NULL CHECK (status IN ('ACTIVE', 'SUSPENDED', 'TERMINATED')),
    last_refresh_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE nj_group_runtime_state IS 'Req: 14 dashboard - group status filter, environment monitoring.';

CREATE TABLE IF NOT EXISTS nj_level_runtime_state
(
    level_id          BIGINT PRIMARY KEY REFERENCES nj_level (level_id) ON DELETE CASCADE,
    current_seed      NUMERIC(20, 10) NOT NULL DEFAULT 0,
    current_prize     NUMERIC(20, 10) NOT NULL DEFAULT 0,
    liability         NUMERIC(20, 10) NOT NULL DEFAULT 0,
    active_players_5m INT             NOT NULL DEFAULT 0,
    stage             TEXT            NOT NULL DEFAULT 'RUNNING' CHECK (stage IN ('RUNNING', 'STAGE1', 'STAGE2')),
    last_update_ts    TIMESTAMPTZ     NOT NULL DEFAULT now()
);

COMMENT ON TABLE nj_level_runtime_state IS 'Req: 14 dashboard - restart value (from config), current seed/prize/liability, active players last 5 minutes, last update seconds, multidrop stage.';
CREATE INDEX IF NOT EXISTS ix_nj_level_runtime_update ON nj_level_runtime_state (last_update_ts DESC);

-- General/Marketing pool accounts (14)
CREATE TABLE IF NOT EXISTS nj_operator_pool_account
(
    pool_account_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operator_id     TEXT            NOT NULL REFERENCES nj_operator (operator_id),
    pool_type       TEXT            NOT NULL CHECK (pool_type IN ('GENERAL', 'MARKETING')),
    balance         NUMERIC(20, 10) NOT NULL DEFAULT 0 CHECK (balance >= 0),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
    UNIQUE (operator_id, pool_type)
);

COMMENT ON TABLE nj_operator_pool_account IS 'Req: 14 dashboard - General Pool & Marketing Pool.';

-- Seed/Prize top-up ledgers (14)
CREATE TABLE IF NOT EXISTS nj_seed_pool_topup_ledger
(
    topup_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    level_id   BIGINT          NOT NULL REFERENCES nj_level (level_id) ON DELETE CASCADE,
    amount     NUMERIC(20, 10) NOT NULL CHECK (amount > 0),
    reason     TEXT,
    actor      TEXT,
    created_at TIMESTAMPTZ     NOT NULL DEFAULT now()
);

COMMENT ON TABLE nj_seed_pool_topup_ledger IS 'Req: 14 dashboard - Seed Pool Top-up manual additions.';

CREATE TABLE IF NOT EXISTS nj_prize_pool_topup_ledger
(
    topup_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    level_id   BIGINT          NOT NULL REFERENCES nj_level (level_id) ON DELETE CASCADE,
    amount     NUMERIC(20, 10) NOT NULL CHECK (amount > 0),
    reason     TEXT,
    actor      TEXT,
    created_at TIMESTAMPTZ     NOT NULL DEFAULT now()
);

COMMENT ON TABLE nj_prize_pool_topup_ledger IS 'Req: 14 dashboard - Prize Pool Top-up manual additions.';

-- Transfer ledger (promotion stopped -> General Pool; plus comment about transferring seed/prize funds out) (14 + 8.7 comment)
CREATE TABLE IF NOT EXISTS nj_fund_transfer_ledger
(
    transfer_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_group_id      BIGINT          REFERENCES nj_group (group_id) ON DELETE SET NULL,
    from_level_id      BIGINT          REFERENCES nj_level (level_id) ON DELETE SET NULL,
    to_pool_account_id BIGINT          REFERENCES nj_operator_pool_account (pool_account_id) ON DELETE SET NULL,
    amount             NUMERIC(20, 10) NOT NULL CHECK (amount > 0),
    reason             TEXT,
    created_at         TIMESTAMPTZ     NOT NULL DEFAULT now()
);

COMMENT ON TABLE nj_fund_transfer_ledger IS 'Req: 14 (General Pool transfer when promotions stopped) + 8.7 comment (funds in seed/prize pools can be transferred out to a central pool when promotion is over).';
CREATE INDEX IF NOT EXISTS ix_nj_transfer_time ON nj_fund_transfer_ledger (created_at DESC);

-- =========================================================
-- 10) Winners List (Req: 14 Figure 45)
-- =========================================================
CREATE TABLE IF NOT EXISTS nj_jackpot_win
(
    win_id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    licensee_id          TEXT            NOT NULL REFERENCES nj_licensee (licensee_id),
    operator_id          TEXT            NOT NULL REFERENCES nj_operator (operator_id),
    player_id_masked     TEXT            NOT NULL,

    group_id             BIGINT          NOT NULL REFERENCES nj_group (group_id) ON DELETE CASCADE,
    level_id             BIGINT          NOT NULL REFERENCES nj_level (level_id) ON DELETE CASCADE,
    trigger_type         TEXT            NOT NULL CHECK (trigger_type IN
                                                         ('FIXED_ODDS',
                                                          'MYSTERY_BOUNDARY',
                                                          'TIMER_COUNTDOWN',
                                                          'MULTIDROP')),

    win_time_engine      TIMESTAMPTZ     NOT NULL, -- timestamp (engine)
    win_time_player      TIMESTAMPTZ,              -- player timestamp (wallet acceptance time)

    win_base_currency    CHAR(3)         NOT NULL,
    win_player_currency  CHAR(3)         NOT NULL,

    win_amount_base      NUMERIC(20, 10) NOT NULL CHECK (win_amount_base >= 0),
    win_amount_player    NUMERIC(20, 2)  NOT NULL CHECK (win_amount_player >= 0),

    win_confirmed_status TEXT            NOT NULL CHECK (win_confirmed_status IN
                                                         ('PAID', 'ERROR',
                                                          'RETRIED',
                                                          'FAILED_TO_SEND')),

    winning_game_id      TEXT            NOT NULL REFERENCES nj_game (game_id),
    bet_value            NUMERIC(20, 10) NOT NULL CHECK (bet_value >= 0)
);

COMMENT ON TABLE nj_jackpot_win IS 'Req: 14 Winners List fields: licensee/operator/player/group/level/trigger/timestamps/win amounts base & player currency/win confirmed/game/bet value.';
CREATE INDEX IF NOT EXISTS ix_nj_win_time ON nj_jackpot_win (win_time_engine DESC);
CREATE INDEX IF NOT EXISTS ix_nj_win_group_time ON nj_jackpot_win (group_id, win_time_engine DESC);

-- =========================================================
-- 11) User access & audit (Req: 7)
-- =========================================================
CREATE TABLE IF NOT EXISTS nj_role
(
    role_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role_name  TEXT        NOT NULL UNIQUE,
    can_read   BOOLEAN     NOT NULL DEFAULT TRUE,
    can_write  BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE nj_role IS 'Req: 7 NJBO Roles tab - role defines in-app permission/action access (read/write).';

CREATE TABLE IF NOT EXISTS nj_group_config_audit_log
(
    audit_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    group_id   BIGINT      REFERENCES nj_group (group_id) ON DELETE SET NULL,
    actor      TEXT,
    action     TEXT        NOT NULL, -- e.g., CREATE_GROUP/UPDATE_GROUP/DEPLOY/SUSPEND/TOPUP
    detail     JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE nj_group_config_audit_log IS 'Req: 7 - audit log of changes to all group configurations; exportable.';
CREATE INDEX IF NOT EXISTS ix_nj_audit_time ON nj_group_config_audit_log (created_at DESC);

-- =========================================================
-- 12) Constraint: sum(level_contrib_pct)=1 per group (Req: 12.1 "total of all levels = 100%")
-- =========================================================
CREATE OR REPLACE FUNCTION nj_trg_check_level_contrib_sum()
    RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    s   NUMERIC;
    gid BIGINT;
BEGIN
    gid := COALESCE(NEW.group_id, OLD.group_id);

    SELECT COALESCE(SUM(level_contrib_pct), 0)
    INTO s
    FROM nj_level
    WHERE group_id = gid;

    IF abs(s - 1.0) > 0.0000001 THEN
        RAISE EXCEPTION 'Level contribution pct sum must be 1.0 for group_id=%, actual=%', gid, s;
    END IF;

    RETURN NULL;
END
$$;

DROP TRIGGER IF EXISTS trg_nj_level_contrib_sum ON nj_level;

CREATE CONSTRAINT TRIGGER trg_nj_level_contrib_sum
    AFTER INSERT OR UPDATE OR DELETE
    ON nj_level
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
EXECUTE FUNCTION nj_trg_check_level_contrib_sum();
