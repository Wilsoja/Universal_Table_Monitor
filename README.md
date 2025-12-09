# Universal_Table_Monitor
Monitor HANA schema &amp; data of one or many tables, email configured SMEs (per table) if something changes over time against initial baseline.  

to-do:
Solution uses SHA-256 hashing for data changes (Might want to change core to SQL "EXCEPT" in the future).


# Pre-reqs:
```
GRANT EXECUTE ON sys.statisticsserver_sendmail_dev TO yourUserName;
```



# Step 1: build control tables & stored procedure

```
CREATE_TABLES.SQL
CREATE_PROCEDURES.SQL

```

# Step 2: configure:
```
-- Example 1: Add small table with detailed tracking
CALL ADD_TABLE_TO_MONITORING('YOUR_SCHEMA', --schema name
 'YOUR_TABLE', --table name
 'SOMEBODY@SOMEWHERE.COM', -- delimit with a semicolon if adding multiple emails
 'SME', --salutation 
'Y', -- monitor schema changes ?
 'Y', ---- monitor data changes ?
 1, -- data change threshold.  10 if you only want to get notified if 10 or more rows have been modified
 15, -- how often should we check ?   default is 30 min
 'Y', -- track detailed changes ?  if yes, it'll keep track of exact data change details, forensic level, before & after.  
 10000, -- max rows for detailed change tracking
 100.00); -- sample percentage.  all rows will be monitored if 100%





```


# Step 3: schedule the stored procedure:

```
run manual:
â Example: Manual monitoring run
â CALL RUN_TABLE_MONITORING();

OR


-- run every 10 minutes
CREATE SCHEDULER JOB JOB_TABLE_MONITORING
	CRON '* * * * * 10 *'
	ENABLE PROCEDURE RUN_TABLE_MONITORING;

-- https://help.sap.com/docs/SAP_HANA_PLATFORM/4fe29514fd584807ac9f2a04f6754767/d7d43d818366460dae1328aab5d5df4f.html?version=2.0.07



/*
To view all created jobs:
select top 1000 * 
from sys.SCHEDULER_JOBS


To see all execution history:
select top 1000 * 
from sys.m_SCHEDULER_jobs
*/
 

```
# Optional stuff:

-- Usage Examples and Best Practices
-- =====================================================

/*
-- STEP 1: Setup Examples
-- ======================

-- Example 1: Add small table with detailed tracking
CALL ADD_TABLE_TO_MONITORING(
'SALES', 'PRODUCTS',
'product.mgr@company.com', 'Product Manager',
'Y', 'Y', 10, 15, 'Y', 10000, 100.00
);

-- Example 2: Add medium table with sampling
CALL ADD_TABLE_TO_MONITORING(
'SALES', 'ORDERS',
'sales.mgr@company.com', 'Sales Manager',
'Y', 'Y', 100, 30, 'Y', 200000, 25.00
);

-- Example 3: Add large table with basic monitoring only
CALL ADD_TABLE_TO_MONITORING(
'LOGS', 'ACCESS_LOG',
'ops.admin@company.com', 'Operations',
'Y', 'Y', 1000, 60, 'N', 0, 100.00
);

-- Initialize baselines after adding tables
CALL INITIALIZE_TABLE_BASELINE('SALES', 'PRODUCTS');
CALL INITIALIZE_TABLE_BASELINE('SALES', 'ORDERS');
CALL INITIALIZE_TABLE_BASELINE('LOGS', 'ACCESS_LOG');

-- STEP 2: Analysis and Testing
-- ============================

-- Analyze table before adding to monitoring
CALL ANALYZE_TABLE_FOR_MONITORING('MYSCHEMA', 'CUSTOMER_DATA');

-- Check analysis results
SELECT * FROM MONITORING_LOG
WHERE CHANGE_TYPE = 'INFO' AND CHANGE_DETAILS LIKE 'TABLE ANALYSIS%'
ORDER BY DETECTED_AT DESC LIMIT 1;

-- Test monitoring run
CALL RUN_TABLE_MONITORING();

-- STEP 3: Monitoring and Maintenance
-- ==================================

-- View current monitoring status
SELECT * FROM V_MONITORING_STATUS;

-- View recent changes
SELECT * FROM V_RECENT_ALERTS WHERE DETECTED_AT >= CURRENT_DATE;

-- View detailed changes by category
SELECT * FROM V_CHANGE_DETAILS
WHERE CHANGE_CATEGORY IN ('INSERTS', 'UPDATES', 'DELETES')
ORDER BY DETECTED_AT DESC;

-- Check for errors
SELECT * FROM MONITORING_LOG
WHERE CHANGE_TYPE = 'ERROR'
ORDER BY DETECTED_AT DESC;

-- View execution trace
SELECT DETECTED_AT, CHANGE_DETAILS
FROM MONITORING_LOG
WHERE CHANGE_TYPE = 'INFO'
AND DETECTED_AT >= ADD_HOURS(CURRENT_TIMESTAMP, -1)
ORDER BY DETECTED_AT;

-- STEP 4: Maintenance Operations
-- ==============================

-- Clean up old data (keep 60 days)
CALL CLEANUP_MONITORING_DATA(60);

-- Remove table from monitoring
CALL REMOVE_TABLE_FROM_MONITORING('MYSCHEMA', 'OLD_TABLE');

-- Update monitoring configuration
UPDATE MONITORING_CONFIG
SET SAMPLE_PERCENTAGE = 10.0, DATA_CHANGE_THRESHOLD = 50
WHERE TABLE_SCHEMA = 'SALES' AND TABLE_NAME = 'ORDERS';

-- Reinitialize baseline after configuration changes
CALL INITIALIZE_TABLE_BASELINE('SALES', 'ORDERS');

-- STEP 5: Advanced Queries
-- ========================

-- Find tables with frequent changes
SELECT TABLE_SCHEMA, TABLE_NAME, COUNT(*) as DAILY_CHANGES
FROM MONITORING_LOG
WHERE CHANGE_TYPE = 'DATA_CHANGE'
AND DETECTED_AT >= CURRENT_DATE
GROUP BY TABLE_SCHEMA, TABLE_NAME
HAVING COUNT(*) > 5
ORDER BY COUNT(*) DESC;

-- Get change trend by day
SELECT TO_DATE(DETECTED_AT) as CHANGE_DATE,
COUNT(*) as TOTAL_CHANGES,
SUM(CASE WHEN CHANGE_DETAILS LIKE '%NEW ROWS%' THEN 1 ELSE 0 END) as INSERTS,
SUM(CASE WHEN CHANGE_DETAILS LIKE '%DELETED%' THEN 1 ELSE 0 END) as DELETES,
SUM(CASE WHEN CHANGE_DETAILS LIKE '%MODIFIED%' THEN 1 ELSE 0 END) as UPDATES
FROM MONITORING_LOG
WHERE CHANGE_TYPE = 'DATA_CHANGE'
AND DETECTED_AT >= ADD_DAYS(CURRENT_TIMESTAMP, -30)
GROUP BY TO_DATE(DETECTED_AT)
ORDER BY CHANGE_DATE DESC;

-- Find schema changes
SELECT TABLE_SCHEMA, TABLE_NAME, CHANGE_DETAILS, DETECTED_AT
FROM MONITORING_LOG
WHERE CHANGE_TYPE = 'SCHEMA_CHANGE'
ORDER BY DETECTED_AT DESC;

-- STEP 6: Automated Scheduling
-- ============================

-- Create monitoring job (requires job scheduling privileges)
CREATE JOB MONITORING_JOB
CRON '0 */30 * * * *'  -- Every 30 minutes
ENABLE
PARAMETERS STATEMENT = 'CALL RUN_TABLE_MONITORING()';

-- Create cleanup job
CREATE JOB MONITORING_CLEANUP_JOB
CRON '0 2 * * *'  -- Daily at 2 AM
ENABLE  
PARAMETERS STATEMENT = 'CALL CLEANUP_MONITORING_DATA(30)';
*/

-- =====================================================
-- INSTALLATION VERIFICATION
-- =====================================================

-- Run this query to verify all components are installed:
/*
SELECT 'Tables' as COMPONENT, COUNT(*) as COUNT
FROM TABLES
WHERE TABLE_NAME IN (
'MONITORING_CONFIG', 'TABLE_SCHEMA_BASELINE', 'TABLE_DATA_BASELINE',
'TABLE_ROW_BASELINE', 'TABLE_KEY_COLUMNS', 'MONITORING_LOG'
)
UNION ALL
SELECT 'Procedures' as COMPONENT, COUNT(*) as COUNT
FROM PROCEDURES
WHERE PROCEDURE_NAME IN (
'DISCOVER_KEY_COLUMNS', 'ADD_TABLE_TO_MONITORING', 'INITIALIZE_ROW_BASELINE',
'INITIALIZE_TABLE_BASELINE', 'CHECK_DETAILED_DATA_CHANGES', 'CHECK_SCHEMA_CHANGES',
'CHECK_DATA_CHANGES', 'SEND_NOTIFICATIONS', 'RUN_TABLE_MONITORING',
'REMOVE_TABLE_FROM_MONITORING', 'CLEANUP_MONITORING_DATA', 'ANALYZE_TABLE_FOR_MONITORING'
)
UNION ALL
SELECT 'Views' as COMPONENT, COUNT(*) as COUNT
FROM VIEWS
WHERE VIEW_NAME IN (
'V_MONITORING_STATUS', 'V_RECENT_ALERTS', 'V_CHANGE_DETAILS'
);
*/

-- =====================================================
-- BEST PRACTICES SUMMARY:
-- =====================================================
-- 1. Start with table analysis before enabling monitoring
-- 2. Use detailed tracking for small/medium critical tables
-- 3. Use sampling for large tables (>50K rows)  
-- 4. Set appropriate thresholds based on table change patterns
-- 5. Regular cleanup of old monitoring data
-- 6. Monitor the monitor - check for errors regularly
-- 7. Test on non-production first
-- 8. Review and adjust sampling percentages based on performance
-- 9. Use appropriate email recipients per table type
-- 10. Schedule regular monitoring jobs for automation
-- =====================================================

