/*
    01_setup.sql
    Creates the DataPipelineDB database, the four schemas (stg, core, rpt, ops),
    and the staging, core, and logging tables.
    Safe to re-run: every object is created only if it does not exist yet.
    Tested target: SQL Server 2016 or newer (needs ISJSON).
*/

-- Create the database
IF DB_ID('DataPipelineDB') IS NULL
    CREATE DATABASE DataPipelineDB;
GO
USE DataPipelineDB;
GO

-- Layers: staging (raw), core (clean), rpt (reporting), ops (logging)
IF SCHEMA_ID('stg')  IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('core') IS NULL EXEC('CREATE SCHEMA core');
IF SCHEMA_ID('rpt')  IS NULL EXEC('CREATE SCHEMA rpt');
IF SCHEMA_ID('ops')  IS NULL EXEC('CREATE SCHEMA ops');
GO

-- Raw CSV landing table: everything is text so the load never fails on bad data
IF OBJECT_ID('stg.orders_raw', 'U') IS NULL
CREATE TABLE stg.orders_raw (
    order_id        NVARCHAR(50),
    customer_id     NVARCHAR(50),
    order_date      NVARCHAR(50),
    amount          NVARCHAR(50),
    status          NVARCHAR(50),
    loaded_at       DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

-- Raw JSON landing table: store the whole document, parse it later with OPENJSON
IF OBJECT_ID('stg.events_json_raw', 'U') IS NULL
CREATE TABLE stg.events_json_raw (
    id              INT IDENTITY(1,1) PRIMARY KEY,
    payload         NVARCHAR(MAX) NOT NULL,
    source_file     NVARCHAR(260),
    loaded_at       DATETIME2 DEFAULT SYSUTCDATETIME(),
    CONSTRAINT ck_payload_is_json CHECK (ISJSON(payload) = 1)
);
GO

-- Clean tables
IF OBJECT_ID('core.customers', 'U') IS NULL
CREATE TABLE core.customers (
    customer_id     INT PRIMARY KEY,
    customer_name   NVARCHAR(100) NOT NULL,
    email           NVARCHAR(200)
);
GO

IF OBJECT_ID('core.orders', 'U') IS NULL
CREATE TABLE core.orders (
    order_id        INT PRIMARY KEY,
    customer_id     INT NOT NULL REFERENCES core.customers(customer_id),
    order_date      DATE NOT NULL,
    amount          DECIMAL(12,2) NOT NULL CHECK (amount >= 0),
    status          VARCHAR(20) NOT NULL
);
GO

-- Error log for TRY...CATCH in your procedures
IF OBJECT_ID('ops.error_log', 'U') IS NULL
CREATE TABLE ops.error_log (
    error_id        INT IDENTITY(1,1) PRIMARY KEY,
    procedure_name  SYSNAME,
    error_number    INT,
    error_message   NVARCHAR(4000),
    error_line      INT,
    logged_at       DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

-- Data quality log: every failed validation check lands here
IF OBJECT_ID('ops.data_quality_log', 'U') IS NULL
CREATE TABLE ops.data_quality_log (
    check_id        INT IDENTITY(1,1) PRIMARY KEY,
    check_name      VARCHAR(100) NOT NULL,
    table_name      SYSNAME NOT NULL,
    failed_rows     INT NOT NULL,
    details         NVARCHAR(500),
    checked_at      DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

-- Quick check: list everything that was created
SELECT s.name AS schema_name, t.name AS table_name
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name IN ('stg', 'core', 'rpt', 'ops')
ORDER BY s.name, t.name;
GO