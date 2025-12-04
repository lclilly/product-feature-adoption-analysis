-- Creating our database where our 4 tables are going to be stored
CREATE DATABASE ProductAnalytics;

-- Setting working context for all my queries
USE ProductAnalytics;

-- Calculating overall feature adoption rates
-- Shows what percentage of users have ever used each feature
WITH feature_adopters AS (
    SELECT feature_name, COUNT(DISTINCT user_id) AS adopters
    FROM feature_events
    WHERE event_type = 'used'
    GROUP BY feature_name
)
SELECT 
    f.feature_name,f.adopters,u.total_users,
    CAST(f.adopters AS FLOAT) / u.total_users * 100 AS adoption_rate_pct,
    CASE 
        WHEN CAST(f.adopters AS FLOAT) / u.total_users < 0.15 THEN 'Zombie Feature'
        WHEN CAST(f.adopters AS FLOAT) / u.total_users < 0.40 THEN 'Low Adoption'
        WHEN CAST(f.adopters AS FLOAT) / u.total_users < 0.70 THEN 'Moderate Adoption'
        ELSE 'High Adoption'
    END AS adoption_status
FROM feature_adopters f
CROSS JOIN (SELECT COUNT(*) AS total_users FROM users) u
ORDER BY adoption_rate_pct DESC;

-- Time to First Use by Feature
-- How long does it take users to discover each feature after signup?
WITH first_use AS (
    SELECT fe.user_id, fe.feature_name, MIN(fe.event_timestamp) AS first_use_date, u.signup_date
    FROM feature_events fe
    JOIN users u ON fe.user_id = u.user_id
    WHERE fe.event_type = 'used'
    GROUP BY fe.user_id, fe.feature_name, u.signup_date
)
SELECT 
    feature_name,
    AVG(DATEDIFF(day, signup_date, first_use_date)) AS avg_days_to_first_use,
    MIN(DATEDIFF(day, signup_date, first_use_date)) AS min_days,
    MAX(DATEDIFF(day, signup_date, first_use_date)) AS max_days,
    COUNT(*) AS total_adopters
FROM first_use
GROUP BY feature_name
ORDER BY avg_days_to_first_use;

-- Power User Analysis
-- Define power users as those who've adopted 5+ features

WITH user_feature_count AS (
    SELECT 
        user_id,
        COUNT(DISTINCT feature_name) AS features_adopted
    FROM feature_events
    WHERE event_type = 'used'
    GROUP BY user_id
),
user_metrics AS (
    SELECT 
        u.user_id,
        u.plan_type,
        ufc.features_adopted,
        AVG(r.mrr) AS avg_mrr,
        AVG(CAST(ret.is_active AS FLOAT)) AS retention_rate,
        CASE 
            WHEN ufc.features_adopted >= 5 THEN 'Power User'
            WHEN ufc.features_adopted >= 3 THEN 'Active User'
            ELSE 'Casual User'
        END AS user_segment
    FROM users u
    LEFT JOIN user_feature_count ufc ON u.user_id = ufc.user_id
    LEFT JOIN revenue r ON u.user_id = r.user_id
    LEFT JOIN retention ret ON u.user_id = ret.user_id
    GROUP BY u.user_id, u.plan_type, ufc.features_adopted
)
SELECT 
    user_segment,
    COUNT(*) AS user_count,
    AVG(features_adopted) AS avg_features_adopted,
    AVG(avg_mrr) AS avg_mrr,
    AVG(retention_rate) AS avg_retention_rate,
    CAST(COUNT(*) AS FLOAT) / (SELECT COUNT(*) FROM users) * 100 AS pct_of_users
FROM user_metrics
GROUP BY user_segment
ORDER BY avg_mrr DESC;

-- Feature co-occurence
-- Which features are commonly used together?

WITH user_features AS (
    SELECT DISTINCT 
        user_id,
        feature_name
    FROM feature_events
    WHERE event_type = 'used'
)
SELECT 
    a.feature_name AS feature_a,
    b.feature_name AS feature_b,
    COUNT(DISTINCT a.user_id) AS users_with_both,
    CAST(COUNT(DISTINCT a.user_id) AS FLOAT) / 
        (SELECT COUNT(DISTINCT user_id) FROM users) * 100 AS co_occurrence_pct
FROM user_features a
JOIN user_features b 
    ON a.user_id = b.user_id 
    AND a.feature_name < b.feature_name
GROUP BY a.feature_name, b.feature_name
HAVING COUNT(DISTINCT a.user_id) > 50
ORDER BY users_with_both DESC;

-- Business Impact Summary
-- The money query
WITH feature_metrics AS (
    SELECT 
        fe.feature_name,
        COUNT(DISTINCT fe.user_id) AS current_adopters,
        (SELECT COUNT(*) FROM users) AS total_users,
        AVG(r.mrr) AS avg_mrr_adopters,
        AVG(CAST(ret.is_active AS FLOAT)) AS avg_retention_adopters  -- CAST to FLOAT first!
    FROM feature_events fe
    JOIN revenue r ON fe.user_id = r.user_id
    JOIN retention ret ON fe.user_id = ret.user_id
    WHERE fe.event_type = 'used'
    GROUP BY fe.feature_name
),
baseline AS (
    SELECT 
        AVG(r.mrr) AS avg_mrr_all,
        AVG(CAST(ret.is_active AS FLOAT)) AS avg_retention_all
    FROM revenue r
    JOIN retention ret ON r.user_id = ret.user_id
)
SELECT 
    fm.feature_name,
    fm.current_adopters,
    fm.total_users,
    CAST(fm.current_adopters AS FLOAT) / fm.total_users * 100 AS current_adoption_pct,
    fm.avg_mrr_adopters,
    b.avg_mrr_all,
    fm.avg_mrr_adopters / NULLIF(b.avg_mrr_all, 0) AS revenue_multiplier,
    fm.avg_retention_adopters,
    b.avg_retention_all,
    (fm.avg_retention_adopters - b.avg_retention_all) * 100 AS retention_lift_pct,
    (fm.total_users * 0.10) * fm.avg_mrr_adopters * 12 AS potential_annual_revenue
FROM feature_metrics fm
CROSS JOIN baseline b
ORDER BY revenue_multiplier DESC;

-- Feature Adoption Impact on Retention
-- Compare retention rates between feature adopters vs non-adopters
WITH user_retention AS (
    SELECT 
        user_id,
        AVG(CAST(is_active AS FLOAT)) AS retention_rate
    FROM retention
    WHERE month >= DATEADD(month, -6, (SELECT MAX(month) FROM retention))
    GROUP BY user_id
),
feature_users AS (
    SELECT DISTINCT
        feature_name,
        user_id
    FROM feature_events
    WHERE event_type = 'used'
)
SELECT 
    fu.feature_name,
    AVG(CASE WHEN fu.user_id IS NOT NULL THEN ur.retention_rate END) AS avg_retention_adopters,
    AVG(CASE WHEN fu.user_id IS NULL THEN ur.retention_rate END) AS avg_retention_non_adopters,
    (AVG(CASE WHEN fu.user_id IS NOT NULL THEN ur.retention_rate END) - 
     AVG(CASE WHEN fu.user_id IS NULL THEN ur.retention_rate END)) AS retention_lift,
    COUNT(DISTINCT fu.user_id) AS adopters_count
FROM user_retention ur
LEFT JOIN feature_users fu ON ur.user_id = fu.user_id
GROUP BY fu.feature_name
HAVING COUNT(DISTINCT fu.user_id) > 0
ORDER BY retention_lift DESC;

-- Feature Adoption Impact on Revenue (FIXED)
-- Which features correlate with higher MRR?
WITH user_revenue AS (
    SELECT 
        user_id,
        AVG(mrr) AS avg_mrr
    FROM revenue
    WHERE month >= DATEADD(month, -6, (SELECT MAX(month) FROM revenue))
    GROUP BY user_id
),
feature_users AS (
    SELECT DISTINCT
        feature_name,
        user_id
    FROM feature_events
    WHERE event_type = 'used'
)
SELECT 
    fu.feature_name,
    AVG(CASE WHEN fu.user_id IS NOT NULL THEN ur.avg_mrr END) AS avg_mrr_adopters,
    AVG(CASE WHEN fu.user_id IS NULL THEN ur.avg_mrr END) AS avg_mrr_non_adopters,
    (AVG(CASE WHEN fu.user_id IS NOT NULL THEN ur.avg_mrr END) / 
     NULLIF(AVG(CASE WHEN fu.user_id IS NULL THEN ur.avg_mrr END), 0)) AS revenue_multiplier,
    COUNT(DISTINCT fu.user_id) AS adopters_count
FROM user_revenue ur
LEFT JOIN feature_users fu ON ur.user_id = fu.user_id
GROUP BY fu.feature_name
HAVING COUNT(DISTINCT fu.user_id) > 0
ORDER BY revenue_multiplier DESC;

-- Feature Adoption by Cohort
-- Do new users adopt features differently?
WITH user_cohorts AS (
    SELECT 
        user_id,
        DATEFROMPARTS(YEAR(signup_date), MONTH(signup_date), 1) AS cohort_month
    FROM users
),
cohort_sizes AS (
    SELECT 
        cohort_month,
        COUNT(*) AS cohort_size
    FROM user_cohorts
    GROUP BY cohort_month
),
feature_adoption_by_cohort AS (
    SELECT 
        uc.cohort_month,
        fe.feature_name,
        COUNT(DISTINCT fe.user_id) AS adopters
    FROM user_cohorts uc
    LEFT JOIN feature_events fe 
        ON uc.user_id = fe.user_id 
        AND fe.event_type = 'used'
    WHERE fe.feature_name IS NOT NULL
    GROUP BY uc.cohort_month, fe.feature_name
)
SELECT 
    fa.cohort_month,
    fa.feature_name,
    fa.adopters,
    cs.cohort_size,
    CAST(fa.adopters AS FLOAT) / cs.cohort_size * 100 AS adoption_rate_pct
FROM feature_adoption_by_cohort fa
JOIN cohort_sizes cs ON fa.cohort_month = cs.cohort_month
WHERE fa.cohort_month >= DATEADD(month, -12, (SELECT MAX(cohort_month) FROM user_cohorts))
ORDER BY fa.cohort_month, adoption_rate_pct DESC;