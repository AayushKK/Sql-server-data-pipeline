/*
    02_load_staging.sql
    Loads customers.csv, orders.csv and events.json into the staging tables.

    Change @data_folder in the EXEC at the bottom if your files are not in C:\datasql\
    Needs SQL Server 2017 or newer (BULK INSERT ... FORMAT = 'CSV').
    Safe to re-run: staging tables are emptied before each load.
*/

USE DataPipelineDB;
GO

-- 1. Extra staging table for customers (all text, like the other raw tables)
IF OBJECT_ID('stg.customers_raw', 'U') IS NULL
CREATE TABLE stg.customers_raw (
    customer_id     NVARCHAR(50),
    customer_name   NVARCHAR(200),
    email           NVARCHAR(200),
    loaded_at       DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

-- 2. Load log: one row per table per run, so you can reconcile counts later
IF OBJECT_ID('ops.load_log', 'U') IS NULL
CREATE TABLE ops.load_log (
    load_id         INT IDENTITY(1,1) PRIMARY KEY,
    run_at          DATETIME2 NOT NULL,
    table_name      SYSNAME NOT NULL,
    source_file     NVARCHAR(260) NOT NULL,
    rows_loaded     INT NOT NULL
);
GO

-- 3. Views that hide the loaded_at column.
--    BULK INSERT expects one file field per table column, so we load through a view.
CREATE OR ALTER VIEW stg.v_customers_load AS
SELECT customer_id, customer_name, email FROM stg.customers_raw;
GO

CREATE OR ALTER VIEW stg.v_orders_load AS
SELECT order_id, customer_id, order_date, amount, status FROM stg.orders_raw;
GO

-- 4. The load procedure
CREATE OR ALTER PROCEDURE stg.usp_load_staging
    @data_folder NVARCHAR(200) = N'C:\datasql\'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @run_at   DATETIME2     = SYSUTCDATETIME();
    DECLARE @file     NVARCHAR(260);
    DECLARE @sql      NVARCHAR(MAX);
    DECLARE @rows     INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- start from empty staging tables
        TRUNCATE TABLE stg.customers_raw;
        TRUNCATE TABLE stg.orders_raw;
        TRUNCATE TABLE stg.events_json_raw;

        -- customers.csv
        SET @file = @data_folder + N'customers.csv';
        SET @sql = N'BULK INSERT stg.v_customers_load FROM ' + QUOTENAME(@file, '''')
                 + N' WITH (FORMAT = ''CSV'', FIRSTROW = 2, CODEPAGE = ''65001'', TABLOCK);';
        EXEC sys.sp_executesql @sql;
        SELECT @rows = COUNT(*) FROM stg.customers_raw;
        INSERT INTO ops.load_log (run_at, table_name, source_file, rows_loaded)
        VALUES (@run_at, 'stg.customers_raw', @file, @rows);

        -- orders.csv
        SET @file = @data_folder + N'orders.csv';
        SET @sql = N'BULK INSERT stg.v_orders_load FROM ' + QUOTENAME(@file, '''')
                 + N' WITH (FORMAT = ''CSV'', FIRSTROW = 2, CODEPAGE = ''65001'', TABLOCK);';
        EXEC sys.sp_executesql @sql;
        SELECT @rows = COUNT(*) FROM stg.orders_raw;
        INSERT INTO ops.load_log (run_at, table_name, source_file, rows_loaded)
        VALUES (@run_at, 'stg.orders_raw', @file, @rows);

        -- events.json: the whole file becomes ONE row, parsed later with OPENJSON
        SET @file = @data_folder + N'events.json';
        SET @sql = N'INSERT INTO stg.events_json_raw (payload, source_file) '
                 + N'SELECT BulkColumn, @src FROM OPENROWSET(BULK ' + QUOTENAME(@file, '''')
                 + N', SINGLE_CLOB) AS j;';
        EXEC sys.sp_executesql @sql, N'@src NVARCHAR(260)', @src = @file;
        SELECT @rows = COUNT(*) FROM stg.events_json_raw;
        INSERT INTO ops.load_log (run_at, table_name, source_file, rows_loaded)
        VALUES (@run_at, 'stg.events_json_raw', @file, @rows);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        INSERT INTO ops.error_log (procedure_name, error_number, error_message, error_line)
        VALUES (OBJECT_NAME(@@PROCID), ERROR_NUMBER(), ERROR_MESSAGE(), ERROR_LINE());

        THROW;  -- pass the original error back to the caller
    END CATCH;

    -- result: what this run loaded
    SELECT table_name, source_file, rows_loaded
    FROM ops.load_log
    WHERE run_at = @run_at
    ORDER BY load_id;
END;
GO

-- 5. Run it
EXEC stg.usp_load_staging @data_folder = N'C:\datasql\';
GO

-- 6. Quick checks: expect 50 customers, 505 orders, 1 JSON document holding 200 events
SELECT 'customers_raw' AS table_name, COUNT(*) AS row_count FROM stg.customers_raw
UNION ALL
SELECT 'orders_raw', COUNT(*) FROM stg.orders_raw
UNION ALL
SELECT 'events_json_raw (documents)', COUNT(*) FROM stg.events_json_raw
UNION ALL
SELECT 'events inside the JSON', COUNT(*)
FROM stg.events_json_raw
CROSS APPLY OPENJSON(payload);
GO

-- Peek at the raw data
SELECT TOP (10) * FROM stg.orders_raw;
SELECT TOP (10) * FROM stg.customers_raw;
GO
