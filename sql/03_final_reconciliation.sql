-- Goal: Calculate the true target_base of 22 for Merchant 501's October 2026 Diwali campaigns.
WITH RECURSIVE
-- Step 1: Pick only finished Diwali campaigns for merchant 501 (ignore drafts).
eligible_campaigns AS (
    SELECT c.id, c.parent_id, c.name
    FROM campaign AS c
    WHERE c.merchant_id = 501
      AND c.name LIKE '%Diwali%'
      AND c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND c.processing_status = 'processed'
),
-- Step 2: Link every retry campaign back to its original parent campaign.
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
-- Step 3: Keep only October sends that actually reached the customer (status 900).
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
-- Step 4: Check which campaigns had retries and which ones were single runs.
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
-- Step 5: For retry campaigns, count each customer only once to prevent double-billing. For single runs, count all valid sends.
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