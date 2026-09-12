-- Check 1: Look at the total raw rows to see starting numbers.
SELECT COUNT(*) AS raw_log_count
FROM communication_log;

-- Check 2: Check campaign names and statuses to find drafts or unapproved runs.
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
GROUP BY c.name, c.creation_status, c.processing_status, c.parent_id
ORDER BY c.name;

-- Check 3: Check delivery codes to separate successful sends from failures.
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

-- Check 4: Check parent-child IDs to find retry campaigns.
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

-- Check 5: Check if the same customers received multiple messages across retries.
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