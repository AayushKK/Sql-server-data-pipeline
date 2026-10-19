# SQL Server Data Pipeline

A T-SQL ETL project that loads messy CSV and JSON data into SQL Server,
validates it, and documents root cause analysis (RCA) for data issues.

## What it covers

- Staging, core, reporting, and ops schemas
- Stored procedures with `TRY...CATCH`, transactions, and error logging
- Scalar and table-valued functions
- Views for reporting
- JSON parsing with `OPENJSON`, `JSON_VALUE`, `JSON_QUERY`, and `FOR JSON`
- Data validation checks logged to `ops.data_quality_log`
- Root cause analysis write-ups in `docs/rca`
- Query troubleshooting: execution plans, indexes, before and after timings

## Architecture

```
CSV + JSON files
      |
      v
  stg (raw text, nothing is rejected)
      |   stored procedures: clean, convert, validate
      v
  core (typed tables with constraints)
      |
      v
  rpt (reporting views)

  ops: error_log and data_quality_log record every failure
```

## Tech

- SQL Server 2019 Developer Edition
- SQL Server Management Studio (SSMS) 22
- T-SQL

## How to run

1. Install SQL Server (2016 or newer) and SSMS.
2. Run the scripts in `sql/` in numeric order on a fresh server.
3. Put the sample files from `data/` in a folder the SQL Server service
   account can read, such as `C:\data\`.

## Project layout

```
sql/        numbered T-SQL scripts, run in order
data/       small sample CSV and JSON files
docs/rca/   root cause analysis write-ups
```

## Scripts

| Script | Purpose |
| --- | --- |
| `01_setup.sql` | Database, schemas, staging, core, and log tables |

## Status

In progress