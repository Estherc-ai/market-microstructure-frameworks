-- =========================================================================================
-- Title: Axis Regime Framework - Structural Zero Gamma (ZG) Isolate Engine
-- Description: Core architectural schema and conditional data matrix used to calculate 
--              aggregate market maker Gamma Exposure (GEX) and identify the Zero Gamma Flip Zone.
-- Framework: Quantitative Market Microstructure & Structural Mechanics
-- Disclaimer: Structural template containing mock database schema and non-proprietary logic maps.
-- =========================================================================================

-- STEP 1: DEFINE STRUCTURAL TRANSACTION DATA LAYOUT
CREATE TABLE IF NOT EXISTS position_ledger_daily (
    record_timestamp      TIMESTAMP NOT NULL,
    underlying_ticker     VARCHAR(10) NOT NULL,
    strike_price          NUMERIC(10, 2) NOT NULL,
    expiration_date       DATE NOT NULL,
    option_type           VARCHAR(4) CHECK (option_type IN ('CALL', 'PUT')),
    open_interest         INT NOT NULL CHECK (open_interest >= 0),
    dealer_gamma          NUMERIC(12, 8) NOT NULL,
    underlying_spot_price NUMERIC(10, 2) NOT NULL,
    data_source           VARCHAR(50),
    session_date          DATE NOT NULL,
    ingestion_timestamp   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (record_timestamp, underlying_ticker, strike_price, expiration_date, option_type)
);

-- STEP 2: ADD PERFORMANCE INDEXES
CREATE INDEX IF NOT EXISTS idx_ticker_expiry 
ON position_ledger_daily(underlying_ticker, expiration_date);

CREATE INDEX IF NOT EXISTS idx_session_date 
ON position_ledger_daily(session_date);

-- STEP 3: BUILD THE CORE STRUCTURAL ALIGNMENT MATRIX
WITH OptionsChainCleanse AS (
    SELECT 
        underlying_ticker AS ticker,
        session_date,
        strike_price,
        option_type,
        open_interest,
        dealer_gamma,
        underlying_spot_price AS spot,
        -- Dollar GEX Formula: OI × 100 × Gamma × Spot² × 0.01
        -- Calls inject positive gamma (stabilizing mean reversion)
        -- Puts inject negative gamma (accelerating directional expansion)
        CASE 
            WHEN option_type = 'CALL' 
            THEN (open_interest * 100.0 * dealer_gamma 
                 * underlying_spot_price 
                 * underlying_spot_price * 0.01)
            WHEN option_type = 'PUT'  
            THEN (open_interest * 100.0 * dealer_gamma 
                 * underlying_spot_price 
                 * underlying_spot_price * 0.01 * -1.0)
            ELSE 0.0 
        END AS absolute_strike_gex
    FROM position_ledger_daily
    WHERE expiration_date > CURRENT_DATE
),

-- STEP 4: AGGREGATE BY STRIKE NODE
StrikeLiquidityClusters AS (
    SELECT 
        ticker,
        session_date,
        spot,
        strike_price,
        SUM(absolute_strike_gex) AS aggregate_strike_gex
    FROM OptionsChainCleanse
    GROUP BY ticker, session_date, spot, strike_price
),

-- STEP 5: NET GEX SUMMARY PER SESSION
SessionGEXSummary AS (
    SELECT
        ticker,
        session_date,
        SUM(CASE WHEN aggregate_strike_gex > 0 
            THEN aggregate_strike_gex ELSE 0 END) AS total_call_gex,
        SUM(CASE WHEN aggregate_strike_gex < 0 
            THEN aggregate_strike_gex ELSE 0 END) AS total_put_gex,
        SUM(aggregate_strike_gex) AS net_session_gex
    FROM StrikeLiquidityClusters
    GROUP BY ticker, session_date
)

-- STEP 6: FINAL OUTPUT - REGIME CLASSIFICATION & RISK DENSITY RANK
SELECT 
    s.ticker,
    s.session_date,
    s.spot AS underlying_market_price,
    s.strike_price AS structural_strike_node,
    s.aggregate_strike_gex AS net_gamma_exposure,
    g.net_session_gex AS session_net_gex,

    -- Regime Classification
    CASE 
        WHEN s.aggregate_strike_gex > 0 
        THEN 'POSITIVE GAMMA REGIME (Mean-Reversion / Absorption Zone)'
        WHEN s.aggregate_strike_gex < 0 
        THEN 'NEGATIVE GAMMA REGIME (High-Velocity Acceleration Zone)'
        ELSE 'ZERO GAMMA AXIS (Systemic Flip Point)'
    END AS structural_regime_bias,

    -- Session Level Regime
    CASE
        WHEN g.net_session_gex > 0 THEN 'POSITIVE SESSION'
        WHEN g.net_session_gex < 0 THEN 'NEGATIVE SESSION'
        ELSE 'ZERO GAMMA SESSION'
    END AS session_regime,

    -- Risk Density Rank
    RANK() OVER (
        PARTITION BY s.ticker, s.session_date 
        ORDER BY ABS(s.aggregate_strike_gex) DESC
    ) AS risk_density_rank

FROM StrikeLiquidityClusters s
JOIN SessionGEXSummary g 
    ON s.ticker = g.ticker 
    AND s.session_date = g.session_date
ORDER BY s.ticker, s.session_date, risk_density_rank ASC;
