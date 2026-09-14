-- Merchant 501, October 2026 reconciliation.
.mode csv

DROP TABLE IF EXISTS campaign;
DROP TABLE IF EXISTS communication_log;

CREATE TABLE campaign (
    id INTEGER,
    merchant_id INTEGER,
    parent_id INTEGER,
    name TEXT,
    creation_status TEXT,
    processing_status TEXT
);

CREATE TABLE communication_log (
    id INTEGER,
    merchant_id INTEGER,
    communication_id INTEGER,
    customer_id TEXT,
    communication_type INTEGER,
    delivery_status INTEGER,
    sent_time TEXT,
    scheduled_time TEXT,
    credit_used INTEGER,
    channel TEXT
);

.import --skip 1 data/raw/campaign.csv campaign
.import --skip 1 data/raw/communication_log.csv communication_log

SELECT COUNT(*) AS total_raw_log_count
FROM communication_log;

SELECT
    c.name,
    c.creation_status,
    c.processing_status,
    c.parent_id,
    COUNT(cl.id) AS log_count
FROM campaign AS c
LEFT JOIN communication_log AS cl
  ON cl.communication_id = c.id
 AND cl.merchant_id = 501
 AND cl.communication_type = 2
 AND cl.sent_time >= '2026-10-01'
 AND cl.sent_time < '2026-11-01'
WHERE c.merchant_id = 501
  AND c.name LIKE '%Diwali%'
GROUP BY c.id, c.name, c.creation_status, c.processing_status, c.parent_id
ORDER BY c.name;

SELECT
    cl.delivery_status,
    COUNT(*) AS log_count,
    COUNT(DISTINCT cl.customer_id) AS unique_customers
FROM communication_log AS cl
JOIN campaign AS c ON c.id = cl.communication_id
WHERE cl.merchant_id = 501
  AND c.merchant_id = 501
  AND cl.communication_type = 2
  AND cl.sent_time >= '2026-10-01'
  AND cl.sent_time < '2026-11-01'
  AND c.name LIKE '%Diwali%'
GROUP BY cl.delivery_status
ORDER BY cl.delivery_status;

SELECT
    c.id AS campaign_id,
    c.parent_id,
    c.name,
    c.creation_status,
    c.processing_status,
    MIN(cl.sent_time) AS first_sent_time,
    MAX(cl.sent_time) AS last_sent_time,
    COUNT(*) AS log_count
FROM campaign AS c
JOIN communication_log AS cl ON cl.communication_id = c.id
WHERE c.merchant_id = 501
  AND cl.merchant_id = 501
  AND cl.communication_type = 2
  AND c.name LIKE '%Diwali%'
GROUP BY c.id, c.parent_id, c.name, c.creation_status, c.processing_status
ORDER BY first_sent_time;

SELECT
    cl.communication_id AS campaign_id,
    cl.customer_id,
    COUNT(*) AS send_count,
    GROUP_CONCAT(cl.id) AS log_ids
FROM communication_log AS cl
JOIN campaign AS c ON c.id = cl.communication_id
WHERE cl.merchant_id = 501
  AND c.merchant_id = 501
  AND cl.communication_type = 2
  AND cl.sent_time >= '2026-10-01'
  AND cl.sent_time < '2026-11-01'
  AND c.name LIKE '%Diwali%'
GROUP BY cl.communication_id, cl.customer_id
HAVING COUNT(*) > 1
ORDER BY send_count DESC;

WITH RECURSIVE
eligible_campaigns AS (
    SELECT c.id, c.parent_id, c.name
    FROM campaign AS c
    WHERE c.merchant_id = 501
      AND c.name LIKE '%Diwali%'
      AND c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND c.processing_status = 'processed'
),

campaign_ancestors (campaign_id, root_id) AS (
    SELECT id, id
    FROM eligible_campaigns
    WHERE parent_id IS NULL

    UNION ALL

    SELECT child.id, parent.root_id
    FROM eligible_campaigns AS child
    JOIN campaign_ancestors AS parent
      ON child.parent_id = parent.campaign_id
),

scoped_deliveries AS (
    SELECT cl.id AS log_id, cl.customer_id, ca.root_id
    FROM communication_log AS cl
    JOIN campaign_ancestors AS ca ON ca.campaign_id = cl.communication_id
    WHERE cl.merchant_id = 501
      AND cl.communication_type = 2
      AND cl.delivery_status = 900
      AND cl.sent_time >= '2026-10-01'
      AND cl.sent_time < '2026-11-01'
),

family_shape AS (
    SELECT root_id,
           EXISTS (
               SELECT 1
               FROM eligible_campaigns AS child
               WHERE child.parent_id = root_id
           ) AS is_retry_family
    FROM campaign_ancestors
    GROUP BY root_id
),

family_totals AS (
    SELECT d.root_id,
           CASE
               WHEN s.is_retry_family THEN COUNT(DISTINCT d.customer_id)
               ELSE COUNT(d.log_id)
           END AS target_base_contribution
    FROM scoped_deliveries AS d
    JOIN family_shape AS s ON s.root_id = d.root_id
    GROUP BY d.root_id, s.is_retry_family
)

SELECT SUM(target_base_contribution) AS target_base
FROM family_totals;