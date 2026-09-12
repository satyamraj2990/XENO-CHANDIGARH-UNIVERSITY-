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