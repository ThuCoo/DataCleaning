-- ==================================================
-- SETTING UP
-- ==================================================
-- Create Database
IF NOT EXISTS (SELECT *
               FROM   sys.databases
               WHERE  name = 'DataCleaning')
    BEGIN
        CREATE DATABASE DataCleaning;
    END

USE DataCleaning;


GO
-- Create Table Shipments
DROP TABLE IF EXISTS shipments;

CREATE TABLE shipments (
    shipment_id       CHAR (8)      PRIMARY KEY,
    origin_warehouse  NVARCHAR (50),
    destination_city  NVARCHAR (50),
    destination_state CHAR (10)    ,
    carrier           NVARCHAR (50),
    ship_date         NVARCHAR (50),
    delivery_date     NVARCHAR (50),
    weight_kg         FLOAT        ,
    freight_cost      FLOAT        ,
    shipment_status   NVARCHAR (50),
    items_count       SMALLINT     ,
    damage_reported   CHAR (10)    
);

-- Insert Data
BULK INSERT dbo.shipments FROM 'dirty_shipments.csv'
    WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', CODEPAGE = '65001');

SELECT *
FROM   dbo.shipments;


GO
-- ==================================================
-- DATA CLEANING
-- ==================================================
-- 1. Removing Leading/ Trailing Whitespaces
SELECT shipment_id,
       TRIM(origin_warehouse) AS origin_warehouse,
       TRIM(destination_city) AS destination_city,
       TRIM(destination_state) AS destination_state,
       TRIM(carrier) AS carrier,
       TRIM(ship_date) AS ship_date,
       TRIM(delivery_date) AS delivery_date,
       TRIM(shipment_status) AS shipment_status,
       TRIM(damage_reported) AS damage_reported
FROM   dbo.shipments;


GO
-- 2.Standardize Text Casing
-- Create INITCAP Function
DROP FUNCTION IF EXISTS dbo.INITCAP;


GO
CREATE FUNCTION dbo.INITCAP
(@input_string NVARCHAR (MAX))
RETURNS NVARCHAR (MAX)
AS
BEGIN
    IF @input_string IS NULL
        RETURN NULL;
    DECLARE @result AS NVARCHAR (MAX);
    SELECT @result = STRING_AGG(UPPER(LEFT(value, 1)) + LOWER(SUBSTRING(value, 2, LEN(value))), ' ') WITHIN GROUP (ORDER BY ordinal)
    FROM   STRING_SPLIT (@input_string, ' ', 1);
    RETURN @result;
END


GO
SELECT shipment_id,
       dbo.INITCAP(origin_warehouse) AS origin_warehouse,
       dbo.INITCAP(destination_city) AS destination_city,
       UPPER(destination_state) AS destination_state,
       dbo.INITCAP(carrier) AS carrier,
       dbo.INITCAP(shipment_status) AS shipment_status,
       dbo.INITCAP(damage_reported) AS damage_reported
FROM   dbo.shipments;

-- 3. Handling NULL and Inconsistent Data
SELECT shipment_id,
       COALESCE (destination_city, 'Unknown') AS destination_city,
       COALESCE (delivery_date, 'Not Yet Delivered') AS delivery_date,
       CASE WHEN damage_reported = 'NULL' THEN NULL ELSE dbo.INITCAP(TRIM(damage_reported)) END AS damage_reported
FROM   dbo.shipments;

-- 4. Remove Exact Duplicates Rows
WITH   ranked
AS     (SELECT *,
               ROW_NUMBER() OVER (PARTITION BY origin_warehouse, destination_city, carrier, ship_date, CAST (weight_kg AS NVARCHAR (50)), CAST (freight_cost AS NVARCHAR (50)) ORDER BY shipment_id) AS row_num
        FROM   dbo.shipments)
SELECT shipment_id,
       origin_warehouse,
       destination_city,
       destination_state,
       carrier,
       ship_date,
       delivery_date,
       weight_kg,
       freight_cost,
       shipment_status,
       items_count,
       damage_reported
FROM   ranked
WHERE  row_num = 1;

-- 5. Fixing Negatives and Suspicious Numeric Values
SELECT shipment_id,
       CASE WHEN weight_kg != 0 THEN ABS(weight_kg) ELSE NULL END AS weight_kg,
       CASE WHEN freight_cost != 0 THEN ABS(freight_cost) ELSE NULL END AS freight_cost,
       CASE WHEN items_count != 0 THEN ABS(items_count) ELSE NULL END AS items_count
FROM   dbo.shipments;

-- 6. Handling Date and Calculate Trasit Days
WITH   cleaned_date
AS     (SELECT shipment_id,
               COALESCE (TRY_CAST (ship_date AS DATE), TRY_CONVERT (DATE, ship_date, 103), TRY_PARSE (ship_date AS DATE USING 'en-us')) AS ship_date,
               COALESCE (TRY_CAST (delivery_date AS DATE), TRY_CONVERT (DATE, delivery_date, 103), TRY_PARSE (delivery_date AS DATE USING 'en-us')) AS delivery_date
        FROM   dbo.shipments)
SELECT *,
       DATEDIFF(DAY, ship_date, delivery_date) AS trasit_days,
       CASE WHEN DATEDIFF(DAY, ship_date, delivery_date) < 0 THEN 'INVALID' WHEN DATEDIFF(DAY, ship_date, delivery_date) = 0 THEN 'SAME DAY DELIVERY' ELSE 'VALID' END AS date_flag
FROM   cleaned_date;

-- 7. Detect and Cap Outliers Using Percentiles
WITH   stats
AS     (SELECT APPROX_PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY freight_cost) AS q1,
               APPROX_PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY freight_cost) AS q3
        FROM   dbo.shipments
        WHERE  freight_cost > 0),
       bounds
AS     (SELECT q1 - 1.5 * (q3 - q1) AS lower_bound,
               q3 + 1.5 * (q3 - q1) AS upper_bound
        FROM   stats)
SELECT sh.shipment_id,
       sh.freight_cost AS original_cost,
       CASE WHEN sh.freight_cost > bd.upper_bound THEN bd.upper_bound WHEN sh.freight_cost < bd.lower_bound THEN bd.lower_bound ELSE sh.freight_cost END AS cleaned_cost,
       CASE WHEN sh.freight_cost > bd.upper_bound
                 OR sh.freight_cost < bd.lower_bound THEN 1 ELSE 0 END AS was_outlier
FROM   dbo.shipments AS sh CROSS JOIN bounds AS bd;


GO
-- 8. Combine All
DROP TABLE IF EXISTS #cleaned;

DROP FUNCTION IF EXISTS dbo.INITCAP;


GO
CREATE FUNCTION dbo.INITCAP
(@input NVARCHAR (MAX))
RETURNS NVARCHAR (MAX)
AS
BEGIN
    IF @input IS NULL
        RETURN NULL;
    DECLARE @result AS NVARCHAR (MAX);
    SELECT @result = STRING_AGG(UPPER(LEFT(value, 1)) + LOWER(SUBSTRING(value, 2, LEN(value))), ' ') WITHIN GROUP (ORDER BY ordinal)
    FROM   STRING_SPLIT (@input, ' ', 1);
    RETURN @result;
END


GO
WITH   stats
AS     (SELECT APPROX_PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY freight_cost) AS q1,
               APPROX_PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY freight_cost) AS q3
        FROM   dbo.shipments
        WHERE  freight_cost > 0),
       bounds
AS     (SELECT q3 + 1.5 * (q3 - q1) AS upper_bound,
               q1 - 1.5 * (q3 - q1) AS lower_bound
        FROM   stats),
       temp
AS     (SELECT shipment_id,
               dbo.INITCAP(TRIM(origin_warehouse)) AS origin_warehouse,
               COALESCE (dbo.INITCAP(TRIM(destination_city)), 'Unknown') AS destination_city,
               UPPER(TRIM(destination_state)) AS destination_state,
               dbo.INITCAP(TRIM(carrier)) AS carrier,
               COALESCE (TRY_CAST (TRIM(ship_date) AS DATE), TRY_CONVERT (DATE, TRIM(ship_date), 103), TRY_PARSE (TRIM(ship_date) AS DATE USING 'en-us')) AS ship_date,
               COALESCE (TRY_CAST (TRIM(delivery_date) AS DATE), TRY_CONVERT (DATE, TRIM(delivery_date), 103), TRY_PARSE (TRIM(delivery_date) AS DATE USING 'en-us')) AS delivery_date,
               CASE WHEN weight_kg != 0 THEN ABS(weight_kg) ELSE NULL END AS weight_kg,
               CASE WHEN freight_cost != 0 THEN ABS(freight_cost) ELSE NULL END AS freight_cost,
               dbo.INITCAP(TRIM(shipment_status)) AS shipment_status,
               CASE WHEN items_count != 0 THEN ABS(items_count) ELSE NULL END AS items_count,
               CASE WHEN dbo.INITCAP(TRIM(damage_reported)) = 'NULL' THEN NULL ELSE dbo.INITCAP(TRIM(damage_reported)) END AS damage_reported,
               ROW_NUMBER() OVER (PARTITION BY origin_warehouse, destination_city, carrier, ship_date, CAST (weight_kg AS NVARCHAR (50)), CAST (freight_cost AS NVARCHAR (50)) ORDER BY shipment_id) AS row_num
        FROM   dbo.shipments),
       ttemp
AS     (SELECT *,
               DATEDIFF(DAY, ship_date, delivery_date) AS transit_days,
               CASE WHEN DATEDIFF(DAY, ship_date, delivery_date) < 0 THEN 'INVALID' WHEN DATEDIFF(DAY, ship_date, delivery_date) = 0 THEN 'SAME DAY DELIVERY' ELSE 'VALID' END AS date_flag,
               CASE WHEN freight_cost > upper_bound THEN upper_bound WHEN freight_cost < lower_bound THEN lower_bound ELSE freight_cost END AS cleaned_cost,
               CASE WHEN freight_cost > upper_bound
                         OR freight_cost < lower_bound THEN 1 ELSE 0 END AS was_outlier
        FROM   temp AS t CROSS JOIN bounds AS b
        WHERE  row_num = 1)
SELECT shipment_id,
       origin_warehouse,
       destination_city,
       destination_state,
       carrier,
       ship_date,
       delivery_date,
       transit_days,
       date_flag,
       weight_kg,
       freight_cost AS original_cost,
       cleaned_cost,
       was_outlier,
       shipment_status,
       items_count,
       damage_reported
INTO   #cleaned
FROM   ttemp;


GO
-- 9. Update Into Database
IF COL_LENGTH('dbo.shipments', 'transit_days') IS NULL
    BEGIN
        ALTER TABLE dbo.shipments
            ADD transit_days INT          ,
                date_flag    NVARCHAR (20),
                cleaned_cost INT          ,
                was_outlier  BIT          ;
    END


GO
UPDATE s
SET    s.origin_warehouse  = c.origin_warehouse,
       s.destination_city  = c.destination_city,
       s.destination_state = c.destination_state,
       s.carrier           = c.carrier,
       s.ship_date         = c.ship_date,
       s.delivery_date     = c.delivery_date,
       s.transit_days      = c.transit_days,
       s.date_flag         = c.date_flag,
       s.weight_kg         = c.weight_kg,
       s.freight_cost      = c.original_cost,
       s.cleaned_cost      = c.cleaned_cost,
       s.was_outlier       = c.was_outlier,
       s.shipment_status   = c.shipment_status,
       s.items_count       = c.items_count,
       s.damage_reported   = c.damage_reported
FROM   dbo.shipments AS s
       INNER JOIN
       #cleaned AS c
       ON c.shipment_id = s.shipment_id;

ALTER TABLE dbo.shipments ALTER COLUMN ship_date DATE;

ALTER TABLE dbo.shipments ALTER COLUMN delivery_date DATE;

EXECUTE sp_rename 'dbo.shipments.freight_cost', 'original_cost', 'COLUMN';