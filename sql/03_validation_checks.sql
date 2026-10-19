/*
    03_validation_checks.sql
    Runs data quality checks on the staging tables and records the results in
    ops.data_quality_log (one row per check per run, failed_rows = 0 means the check passed).

    Run it after 02_load_staging.sql. It does not change any data in stg or core.
    Safe to re-run: each run adds a new set of rows to the log.
*/

USE DataPipelineDB;
GO

CREATE OR ALTER PROCEDURE ops.usp_validate_staging
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @r TABLE (
        check_name   VARCHAR(100),
        table_name   SYSNAME,
        failed_rows  INT,
        details      NVARCHAR(500)
    );

    BEGIN TRY

        /* ---------------- ORDERS ---------------- */

        INSERT INTO @r VALUES ('duplicate_order_id', 'stg.orders_raw',
            (SELECT COALESCE(SUM(c - 1), 0)
             FROM (SELECT COUNT(*) AS c FROM stg.orders_raw GROUP BY order_id HAVING COUNT(*) > 1) d),
            N'extra copies of an order_id that appears more than once');

        INSERT INTO @r VALUES ('missing_amount', 'stg.orders_raw',
            (SELECT COUNT(*) FROM stg.orders_raw WHERE amount IS NULL OR LTRIM(RTRIM(amount)) = ''),
            N'amount is NULL or blank');

        INSERT INTO @r VALUES ('non_numeric_amount', 'stg.orders_raw',
            (SELECT COUNT(*) FROM stg.orders_raw WHERE amount LIKE '%[^0-9.-]%'),
            N'amount contains characters other than digits, dot or minus (for example a currency symbol)');

        INSERT INTO @r VALUES ('negative_amount', 'stg.orders_raw',
            (SELECT COUNT(*) FROM stg.orders_raw WHERE TRY_CAST(amount AS DECIMAL(12,2)) < 0),
            N'amount is below zero');

        INSERT INTO @r VALUES ('invalid_order_date', 'stg.orders_raw',
            (SELECT COUNT(*) FROM stg.orders_raw
             WHERE LTRIM(RTRIM(order_date)) <> '' AND TRY_CONVERT(DATE, order_date, 23) IS NULL),
            N'order_date is not a real date in yyyy-mm-dd format');

        INSERT INTO @r VALUES ('order_date_out_of_range', 'stg.orders_raw',
            (SELECT COUNT(*) FROM stg.orders_raw o
             CROSS APPLY (SELECT TRY_CONVERT(DATE, o.order_date, 23) AS dt) d
             WHERE d.dt IS NOT NULL
               AND (d.dt < '2020-01-01' OR d.dt > CAST(SYSUTCDATETIME() AS DATE))),
            N'valid date but before 2020 or in the future');

        INSERT INTO @r VALUES ('orphan_customer_id', 'stg.orders_raw',
            (SELECT COUNT(*) FROM stg.orders_raw o
             WHERE NOT EXISTS (SELECT 1 FROM stg.customers_raw c WHERE c.customer_id = o.customer_id)),
            N'order refers to a customer_id that is not in customers');

        INSERT INTO @r VALUES ('status_not_allowed', 'stg.orders_raw',
            (SELECT COUNT(*) FROM stg.orders_raw
             WHERE status IS NULL
                OR LOWER(LTRIM(RTRIM(status))) NOT IN ('pending', 'shipped', 'delivered', 'cancelled')),
            N'status is missing or not one of pending, shipped, delivered, cancelled');

        INSERT INTO @r VALUES ('status_needs_standardising', 'stg.orders_raw',
            (SELECT COUNT(*) FROM stg.orders_raw
             WHERE status COLLATE Latin1_General_CS_AS <> LOWER(LTRIM(RTRIM(status)))),
            N'status has capital letters or extra spaces');

        /* ---------------- CUSTOMERS ---------------- */

        INSERT INTO @r VALUES ('duplicate_customer_id', 'stg.customers_raw',
            (SELECT COALESCE(SUM(c - 1), 0)
             FROM (SELECT COUNT(*) AS c FROM stg.customers_raw GROUP BY customer_id HAVING COUNT(*) > 1) d),
            N'extra copies of a customer_id');

        INSERT INTO @r VALUES ('missing_email', 'stg.customers_raw',
            (SELECT COUNT(*) FROM stg.customers_raw WHERE email IS NULL OR LTRIM(RTRIM(email)) = ''),
            N'email is NULL or blank');

        INSERT INTO @r VALUES ('invalid_email', 'stg.customers_raw',
            (SELECT COUNT(*) FROM stg.customers_raw
             WHERE LTRIM(RTRIM(email)) <> '' AND email NOT LIKE '%_@_%._%'),
            N'email does not look like name@domain.tld');

        INSERT INTO @r VALUES ('name_has_extra_spaces', 'stg.customers_raw',
            (SELECT COUNT(*) FROM stg.customers_raw WHERE customer_name <> LTRIM(RTRIM(customer_name))),
            N'customer_name has leading or trailing spaces');

        /* ---------------- EVENTS (JSON) ---------------- */

        INSERT INTO @r VALUES ('json_schema_drift_timestamp', 'stg.events_json_raw',
            (SELECT COUNT(*)
             FROM stg.events_json_raw r CROSS APPLY OPENJSON(r.payload) e
             WHERE JSON_VALUE(e.value, '$.timestamp') IS NULL
               AND JSON_VALUE(e.value, '$.event_time') IS NOT NULL),
            N'events use event_time instead of timestamp');

        INSERT INTO @r VALUES ('json_timestamp_has_offset', 'stg.events_json_raw',
            (SELECT COUNT(*)
             FROM stg.events_json_raw r CROSS APPLY OPENJSON(r.payload) e
             WHERE JSON_VALUE(e.value, '$.timestamp') LIKE '%[+-][0-9][0-9]:[0-9][0-9]'),
            N'timestamp carries a time zone offset instead of Z (UTC)');

        INSERT INTO @r VALUES ('json_missing_customer', 'stg.events_json_raw',
            (SELECT COUNT(*)
             FROM stg.events_json_raw r CROSS APPLY OPENJSON(r.payload) e
             WHERE JSON_QUERY(e.value, '$.customer') IS NULL),
            N'event has no customer object');

        INSERT INTO @r VALUES ('json_unknown_customer', 'stg.events_json_raw',
            (SELECT COUNT(*)
             FROM stg.events_json_raw r CROSS APPLY OPENJSON(r.payload) e
             CROSS APPLY (SELECT COALESCE(JSON_VALUE(e.value, '$.customer.id'),
                                          JSON_VALUE(e.value, '$.customer.customer_id')) AS cid) x
             WHERE x.cid IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM stg.customers_raw c WHERE c.customer_id = x.cid)),
            N'event refers to a customer id that is not in customers');

        INSERT INTO @r VALUES ('json_no_items', 'stg.events_json_raw',
            (SELECT COUNT(*)
             FROM stg.events_json_raw r CROSS APPLY OPENJSON(r.payload) e
             WHERE COALESCE(JSON_QUERY(e.value, '$.items'), JSON_QUERY(e.value, '$.line_items')) IS NULL
                OR COALESCE(JSON_QUERY(e.value, '$.items'), JSON_QUERY(e.value, '$.line_items')) = '[]'),
            N'event has null or empty items / line_items');

        INSERT INTO @r VALUES ('json_event_type_not_allowed', 'stg.events_json_raw',
            (SELECT COUNT(*)
             FROM stg.events_json_raw r CROSS APPLY OPENJSON(r.payload) e
             WHERE JSON_VALUE(e.value, '$.event_type') COLLATE Latin1_General_CS_AS
                   NOT IN ('page_view', 'add_to_cart', 'checkout', 'purchase')),
            N'event_type is not one of the four expected lower-case values');

        INSERT INTO @r VALUES ('json_price_not_numeric', 'stg.events_json_raw',
            (SELECT COUNT(*)
             FROM stg.events_json_raw r CROSS APPLY OPENJSON(r.payload) e
             CROSS APPLY OPENJSON(COALESCE(JSON_QUERY(e.value, '$.items'),
                                           JSON_QUERY(e.value, '$.line_items'), '[]')) i
             WHERE TRY_CAST(JSON_VALUE(i.value, '$.price') AS DECIMAL(10,2)) IS NULL),
            N'an item price is missing or not a number');

        /* ---------------- save and show the results ---------------- */

        INSERT INTO ops.data_quality_log (check_name, table_name, failed_rows, details)
        SELECT check_name, table_name, failed_rows, details FROM @r;

    END TRY
    BEGIN CATCH
        INSERT INTO ops.error_log (procedure_name, error_number, error_message, error_line)
        VALUES (OBJECT_NAME(@@PROCID), ERROR_NUMBER(), ERROR_MESSAGE(), ERROR_LINE());
        THROW;
    END CATCH;

    SELECT
        CASE WHEN failed_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS result,
        check_name, table_name, failed_rows, details
    FROM @r
    ORDER BY CASE WHEN failed_rows = 0 THEN 1 ELSE 0 END, table_name, check_name;
END;
GO

-- Run all checks
EXEC ops.usp_validate_staging;
GO
