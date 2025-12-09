CREATE or replace PROCEDURE DISCOVER_KEY_COLUMNS(
IN p_schema NVARCHAR(256),
IN p_table NVARCHAR(256)
)
LANGUAGE SQLSCRIPT
----SQL SECURITY DEFINER
AS
BEGIN
DECLARE v_has_pk INTEGER := 0;


-- Clear existing key column info
DELETE FROM TABLE_KEY_COLUMNS 
WHERE TABLE_SCHEMA = :p_schema AND TABLE_NAME = :p_table;

-- First, try to find primary key columns
INSERT INTO TABLE_KEY_COLUMNS (
    TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, IS_PRIMARY_KEY
)
SELECT distinct
    :p_schema,
    :p_table,
    CC.COLUMN_NAME,
    TC.POSITION,
    'Y'
FROM SYS.CONSTRAINTS c
INNER JOIN SYS.CONSTRAINTS cc ON c.CONSTRAINT_NAME = cc.CONSTRAINT_NAME
INNER JOIN TABLE_COLUMNS tc ON cc.SCHEMA_NAME = tc.SCHEMA_NAME 
                            AND cc.TABLE_NAME = tc.TABLE_NAME 
                            AND cc.COLUMN_NAME = tc.COLUMN_NAME
WHERE c.SCHEMA_NAME = :p_schema 
  AND c.TABLE_NAME = :p_table
  AND c.IS_PRIMARY_KEY = 'TRUE';

SELECT COUNT(*) INTO v_has_pk 
FROM TABLE_KEY_COLUMNS 
WHERE TABLE_SCHEMA = :p_schema AND TABLE_NAME = :p_table AND IS_PRIMARY_KEY = 'Y';

-- If no primary key, look for unique constraints
IF :v_has_pk = 0 THEN
    INSERT INTO TABLE_KEY_COLUMNS (
        TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, IS_UNIQUE_KEY
    )
    SELECT 
        :p_schema,
        :p_table,
        CC.COLUMN_NAME,
        TC.POSITION,
        'Y'
    FROM CONSTRAINTS c
    INNER JOIN SYS.CONSTRAINTS cc ON c.CONSTRAINT_NAME = cc.CONSTRAINT_NAME
    INNER JOIN TABLE_COLUMNS tc ON cc.SCHEMA_NAME = tc.SCHEMA_NAME 
                                AND cc.TABLE_NAME = tc.TABLE_NAME 
                                AND cc.COLUMN_NAME = tc.COLUMN_NAME
    WHERE c.SCHEMA_NAME = :p_schema 
      AND c.TABLE_NAME = :p_table
      AND c.IS_UNIQUE_KEY = 'TRUE'
    LIMIT 5; -- Limit to first 5 columns of first unique constraint
END IF;

-- If still no key columns, use first few columns as pseudo-key
IF :v_has_pk = 0 AND NOT EXISTS(SELECT 1 FROM TABLE_KEY_COLUMNS WHERE TABLE_SCHEMA = :p_schema AND TABLE_NAME = :p_table) THEN
    INSERT INTO TABLE_KEY_COLUMNS (
        TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, IS_PRIMARY_KEY
    )
    SELECT 
        :p_schema,
        :p_table,
        COLUMN_NAME,
        POSITION,
        'Y'
    FROM TABLE_COLUMNS 
    WHERE SCHEMA_NAME = :p_schema AND TABLE_NAME = :p_table
    ORDER BY POSITION
    LIMIT 3; -- Use first 3 columns as pseudo-primary key
END IF;


END;


CREATE OR REPLACE PROCEDURE ADD_TABLE_TO_MONITORING(
IN p_schema NVARCHAR(256),
IN p_table NVARCHAR(256),
IN p_sme_email NVARCHAR(500),
IN p_sme_name NVARCHAR(256) DEFAULT NULL,
IN p_monitor_schema CHAR(1) DEFAULT 'Y',
IN p_monitor_data CHAR(1) DEFAULT 'Y',
IN p_data_threshold INTEGER DEFAULT 100,
IN p_check_frequency INTEGER DEFAULT 30,
IN p_detailed_tracking CHAR(1) DEFAULT 'N',
IN p_max_rows_detailed INTEGER DEFAULT 10000,
IN p_sample_percentage DECIMAL(5,2) DEFAULT 100.00
)
LANGUAGE SQLSCRIPT
--SQL SECURITY DEFINER
AS
BEGIN
-- Add to monitoring configuration
INSERT INTO MONITORING_CONFIG (
TABLE_SCHEMA, TABLE_NAME, SME_EMAIL, SME_NAME,
MONITOR_SCHEMA_CHANGES, MONITOR_DATA_CHANGES,
DATA_CHANGE_THRESHOLD, CHECK_FREQUENCY_MINUTES,
TRACK_DETAILED_CHANGES, MAX_ROWS_FOR_DETAILED_TRACKING, SAMPLE_PERCENTAGE
) VALUES (
:p_schema, :p_table, :p_sme_email, :p_sme_name,
:p_monitor_schema, :p_monitor_data,
:p_data_threshold, :p_check_frequency,
:p_detailed_tracking, :p_max_rows_detailed, :p_sample_percentage
);




-- Initialize baseline
CALL INITIALIZE_TABLE_BASELINE(:p_schema, :p_table);

-- Initialize baseline will be called separately
INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
VALUES ('INFO', 'Added ' || :p_schema || '.' || :p_table || ' to monitoring configuration');


END;


CREATE PROCEDURE INITIALIZE_ROW_BASELINE(
IN p_schema NVARCHAR(256),
IN p_table NVARCHAR(256)
)
LANGUAGE SQLSCRIPT
--SQL SECURITY DEFINER
AS
BEGIN
DECLARE v_key_columns NVARCHAR(2000);
DECLARE v_all_columns NVARCHAR(20000);
DECLARE v_sql NVARCHAR(20000);
DECLARE v_sample_pct DECIMAL(5,2);
DECLARE v_json_columns NVARCHAR(20000);


-- Get sampling percentage
SELECT COALESCE(SAMPLE_PERCENTAGE, 100.00) INTO v_sample_pct
FROM MONITORING_CONFIG 
WHERE TABLE_SCHEMA = :p_schema AND TABLE_NAME = :p_table;

-- Build key column list for hashing
SELECT STRING_AGG('COALESCE(TO_VARCHAR("' || COLUMN_NAME || '"), ''NULL'')', ' || ''|'' || ' ORDER BY ORDINAL_POSITION ASC)
INTO v_key_columns
FROM TABLE_KEY_COLUMNS 
WHERE TABLE_SCHEMA = :p_schema AND TABLE_NAME = :p_table;


-- Build all column list for data hashing and JSON
SELECT STRING_AGG('COALESCE(TO_VARCHAR("' || COLUMN_NAME || '"), ''NULL'')', ' || ''|'' || ' ORDER BY POSITION ASC)
INTO v_all_columns
FROM TABLE_COLUMNS 
WHERE SCHEMA_NAME = :p_schema AND TABLE_NAME = :p_table;


-- Build JSON column list for detailed comparison
SELECT STRING_AGG('"' || COLUMN_NAME || '": '' || COALESCE(''"'' || TO_VARCHAR("' || COLUMN_NAME || '") || ''"'', ''null'') || ''', ', ' ORDER BY POSITION ASC)
INTO v_json_columns
FROM TABLE_COLUMNS 
WHERE SCHEMA_NAME = :p_schema AND TABLE_NAME = :p_table;


-- Remove trailing comma
v_json_columns := RTRIM(:v_json_columns, ', ');

-- Build dynamic SQL to populate row baseline
v_sql := 'INSERT INTO TABLE_ROW_BASELINE (TABLE_SCHEMA, TABLE_NAME, ROW_KEY_HASH, ROW_DATA_HASH, ROW_DATA_JSON) ' ||
         'SELECT ''' || :p_schema || ''', ''' || :p_table || ''', ' ||
         'HASH_MD5(TO_BINARY(' || :v_key_columns || ')), ' ||
         'HASH_MD5(TO_BINARY(' || :v_all_columns || ')), ' ||
         '''{' || :v_json_columns || '}'' ' ||
         'FROM "' || :p_schema || '"."' || :p_table || '"';

-- Add sampling if not 100%
IF :v_sample_pct < 100.00 THEN
    v_sql := :v_sql || ' TABLESAMPLE BERNOULLI(' || TO_VARCHAR(:v_sample_pct) || ')';
END IF;

EXECUTE IMMEDIATE :v_sql;


END;


CREATE OR REPLACE PROCEDURE INITIALIZE_TABLE_BASELINE(
IN p_schema NVARCHAR(256),
IN p_table NVARCHAR(256)
)
LANGUAGE SQLSCRIPT
--SQL SECURITY DEFINER
AS
BEGIN
DECLARE v_sql NVARCHAR(20000);
DECLARE v_row_count BIGINT;
DECLARE v_checksum NVARCHAR(32);
DECLARE v_detailed_tracking CHAR(1);
DECLARE v_max_rows INTEGER;


INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
VALUES ('INFO', 'Starting baseline initialization for ' || :p_schema || '.' || :p_table);

-- Check if detailed tracking is enabled for this table
SELECT COALESCE(TRACK_DETAILED_CHANGES, 'N'), COALESCE(MAX_ROWS_FOR_DETAILED_TRACKING, 10000)
INTO v_detailed_tracking, v_max_rows
FROM MONITORING_CONFIG 
WHERE TABLE_SCHEMA = :p_schema AND TABLE_NAME = :p_table AND IS_ACTIVE = 'Y';

-- Clear existing baselines
DELETE FROM TABLE_SCHEMA_BASELINE 
WHERE TABLE_SCHEMA = :p_schema AND TABLE_NAME = :p_table;

DELETE FROM TABLE_DATA_BASELINE 
WHERE TABLE_SCHEMA = :p_schema AND TABLE_NAME = :p_table;

DELETE FROM TABLE_ROW_BASELINE 
WHERE TABLE_SCHEMA = :p_schema AND TABLE_NAME = :p_table;

-- Initialize schema baseline
INSERT INTO TABLE_SCHEMA_BASELINE (
    TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION,
    DATA_TYPE_NAME, LENGTH, SCALE, IS_NULLABLE, DEFAULT_VALUE, COMMENTS
)
SELECT 
    SCHEMA_NAME,
    TABLE_NAME,
    COLUMN_NAME,
    POSITION,
    DATA_TYPE_NAME,
    LENGTH,
    SCALE,
    IS_NULLABLE,
    DEFAULT_VALUE,
    COMMENTS
FROM TABLE_COLUMNS
WHERE SCHEMA_NAME = :p_schema AND TABLE_NAME = :p_table;

-- Get row count
v_sql := 'SELECT COUNT(*) FROM "' || :p_schema || '"."' || :p_table || '"';
EXECUTE IMMEDIATE :v_sql INTO v_row_count;

-- Calculate simple checksum using row count
v_checksum := TO_VARCHAR(:v_row_count) || '-SIMPLE';

-- Initialize data baseline
INSERT INTO TABLE_DATA_BASELINE (
    TABLE_SCHEMA, TABLE_NAME, ROW_COUNT, DATA_CHECKSUM, LAST_UPDATE_TIME
)
VALUES (
    :p_schema, :p_table, :v_row_count, :v_checksum, CURRENT_TIMESTAMP
);

INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
VALUES ('INFO', 'Basic baseline created - Row count: ' || TO_VARCHAR(:v_row_count) || 
        ', Detailed tracking: ' || :v_detailed_tracking);

-- If detailed tracking is enabled and table size is manageable
IF :v_detailed_tracking = 'Y' AND :v_row_count <= :v_max_rows THEN
    -- Discover key columns
    CALL DISCOVER_KEY_COLUMNS(:p_schema, :p_table);
    
    -- Initialize detailed row baseline
    CALL INITIALIZE_ROW_BASELINE(:p_schema, :p_table);
    
    INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
    VALUES ('INFO', 'Detailed row baseline created for ' || :p_schema || '.' || :p_table);
ELSEIF :v_detailed_tracking = 'Y' AND :v_row_count > :v_max_rows THEN
    INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
    VALUES ('INFO', 'Table too large for detailed tracking (' || TO_VARCHAR(:v_row_count) || 
            ' > ' || TO_VARCHAR(:v_max_rows) || ') - using basic monitoring only');
END IF;


END;

CREATE PROCEDURE CHECK_DETAILED_DATA_CHANGES(
    IN p_schema NVARCHAR(256),
    IN p_table NVARCHAR(256)
)
LANGUAGE SQLSCRIPT
--SQL SECURITY DEFINER
AS
BEGIN
    DECLARE v_key_columns NVARCHAR(20000);
    DECLARE v_all_columns NVARCHAR(20000);
    DECLARE v_json_columns NVARCHAR(20000);
    DECLARE v_sql NVARCHAR(50000);
    DECLARE v_changes NCLOB;
    DECLARE v_change_count INTEGER;

    INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
    VALUES ('INFO', 'Starting detailed change detection for ' || :p_schema || '.' || :p_table);

   /*
    -- Build column lists using correct system views
    -- Get primary key columns (or use all columns if no PK defined)
    SELECT STRING_AGG('COALESCE(TO_VARCHAR("' || ic.COLUMN_NAME || '"), ''NULL'')', ' || ''|'' || ' ORDER BY ic.POSITION ASC)
    INTO v_key_columns
    FROM SYS.CONSTRAINTS c
    INNER JOIN SYS.INDEX_COLUMNS ic ON c.CONSTRAINT_NAME = ic.INDEX_NAME AND c.SCHEMA_NAME = ic.SCHEMA_NAME
    WHERE c.SCHEMA_NAME = :p_schema
      AND c.TABLE_NAME = :p_table
      AND c.IS_PRIMARY_KEY = 'TRUE';
*/

-- Build key column list for hashing
SELECT STRING_AGG('COALESCE(TO_VARCHAR("' || COLUMN_NAME || '"), ''NULL'')', ' || ''|'' || ' ORDER BY ORDINAL_POSITION ASC)
INTO v_key_columns
FROM TABLE_KEY_COLUMNS 
WHERE TABLE_SCHEMA = :p_schema AND TABLE_NAME = :p_table;

    -- If no primary key found, use all columns as key
    IF :v_key_columns IS NULL THEN
        SELECT STRING_AGG('COALESCE(TO_VARCHAR("' || COLUMN_NAME || '"), ''NULL'')', ' || ''|'' || ' ORDER BY POSITION ASC)
        INTO v_key_columns
        FROM SYS.TABLE_COLUMNS
        WHERE SCHEMA_NAME = :p_schema AND TABLE_NAME = :p_table;
    END IF;

    -- Get all columns
    SELECT STRING_AGG('COALESCE(TO_VARCHAR("' || COLUMN_NAME || '"), ''NULL'')', ' || ''|'' || ' ORDER BY POSITION ASC)
    INTO v_all_columns
    FROM SYS.TABLE_COLUMNS
    WHERE SCHEMA_NAME = :p_schema AND TABLE_NAME = :p_table;

    -- Build JSON representation with proper type handling and escaping
    SELECT STRING_AGG(
        ' ''"'' || ' || COLUMN_NAME || ' || ''": '' || ' ||
        CASE
            WHEN DATA_TYPE_NAME = 'BOOLEAN' THEN
                'CASE WHEN "' || COLUMN_NAME || '" IS NULL THEN ''null'' WHEN "' || COLUMN_NAME || '" = TRUE THEN ''true'' ELSE ''false'' END'
            WHEN DATA_TYPE_NAME IN ('TINYINT', 'SMALLINT', 'INTEGER', 'BIGINT', 'DECIMAL', 'SMALLDECIMAL', 'REAL', 'DOUBLE') THEN
                'COALESCE(TO_VARCHAR("' || COLUMN_NAME || '"), ''null'')'
            ELSE
                'COALESCE( ''"'' || REPLACE(REPLACE(TO_NVARCHAR("' || COLUMN_NAME || '"), ''\'', ''\\''), ''"'', ''\"'' ) || ''"'', ''null'')'
        END
        , ' || '','' || ' ORDER BY POSITION ASC)
    INTO v_json_columns
    FROM SYS.TABLE_COLUMNS
    WHERE SCHEMA_NAME = :p_schema AND TABLE_NAME = :p_table;

    -- Drop temporary table if exists with proper error handling
    BEGIN
        DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN END;
        DROP TABLE #CURRENT_DATA;
    END;

    -- Create temporary table directly (not through dynamic SQL)
    CREATE LOCAL TEMPORARY COLUMN TABLE #CURRENT_DATA (
        ROW_KEY_HASH NVARCHAR(64),
        ROW_DATA_HASH NVARCHAR(64),
        ROW_DATA_JSON NCLOB
    );

    -- Populate the temporary table using dynamic SQL
    v_sql := 'INSERT INTO #CURRENT_DATA ' ||
             'SELECT ' ||
             'BINTOHEX(HASH_MD5(TO_BINARY(' || :v_key_columns || '))), ' ||
             'BINTOHEX(HASH_MD5(TO_BINARY(' || :v_all_columns || '))), ' ||
             '''{'' || ' || :v_json_columns || ' || ''}'' ' ||
             'FROM "' || :p_schema || '"."' || :p_table || '"';

    EXECUTE IMMEDIATE :v_sql;

-- Find new rows (in current but not in baseline) - FIXED LOGIC
v_change_count := 0;
v_changes := '';

-- First check if we have any new rows
SELECT COUNT(*) INTO v_change_count
FROM #CURRENT_DATA cd
WHERE NOT EXISTS (
    SELECT 1 FROM TABLE_ROW_BASELINE rb
    WHERE rb.TABLE_SCHEMA = :p_schema
      AND rb.TABLE_NAME = :p_table
      AND rb.ROW_KEY_HASH = cd.ROW_KEY_HASH
);

-- If we found new rows, get the details
IF :v_change_count > 0 THEN
    SELECT STRING_AGG(SUBSTR(ROW_DATA_JSON, 1, 200), CHAR(10) || '---' || CHAR(10))
    INTO v_changes
    FROM (
        SELECT ROW_DATA_JSON
        FROM #CURRENT_DATA cd
        WHERE NOT EXISTS (
            SELECT 1 FROM TABLE_ROW_BASELINE rb
            WHERE rb.TABLE_SCHEMA = :p_schema
              AND rb.TABLE_NAME = :p_table
              AND rb.ROW_KEY_HASH = cd.ROW_KEY_HASH
        )
        LIMIT 10  -- Limit to first 10 for email readability
    );

    INSERT INTO MONITORING_LOG (
        TABLE_SCHEMA, TABLE_NAME, CHANGE_TYPE, CHANGE_DETAILS
    ) VALUES (
        :p_schema, :p_table, 'DATA_CHANGE',
        'NEW ROWS ADDED (' || TO_VARCHAR(:v_change_count) || ' rows):' || CHAR(10) || COALESCE(:v_changes, 'No details available')
    );
END IF;

-- Find deleted rows (in baseline but not in current) - FIXED LOGIC
v_change_count := 0;
v_changes := '';

SELECT COUNT(*) INTO v_change_count
FROM TABLE_ROW_BASELINE rb
WHERE rb.TABLE_SCHEMA = :p_schema
  AND rb.TABLE_NAME = :p_table
  AND NOT EXISTS (
      SELECT 1 FROM #CURRENT_DATA cd
      WHERE cd.ROW_KEY_HASH = rb.ROW_KEY_HASH
  );

IF :v_change_count > 0 THEN
    SELECT STRING_AGG(SUBSTR(ROW_DATA_JSON, 1, 200), CHAR(10) || '---' || CHAR(10))
    INTO v_changes
    FROM (
        SELECT ROW_DATA_JSON
        FROM TABLE_ROW_BASELINE rb
        WHERE rb.TABLE_SCHEMA = :p_schema
          AND rb.TABLE_NAME = :p_table
          AND NOT EXISTS (
              SELECT 1 FROM #CURRENT_DATA cd
              WHERE cd.ROW_KEY_HASH = rb.ROW_KEY_HASH
          )
        LIMIT 10
    );

    INSERT INTO MONITORING_LOG (
        TABLE_SCHEMA, TABLE_NAME, CHANGE_TYPE, CHANGE_DETAILS
    ) VALUES (
        :p_schema, :p_table, 'DATA_CHANGE',
        'ROWS DELETED (' || TO_VARCHAR(:v_change_count) || ' rows):' || CHAR(10) || COALESCE(:v_changes, 'No details available')
    );
END IF;

-- Find modified rows (same key, different data hash) - FIXED LOGIC
v_change_count := 0;
v_changes := '';

SELECT COUNT(*) INTO v_change_count
FROM TABLE_ROW_BASELINE rb
INNER JOIN #CURRENT_DATA cd ON rb.ROW_KEY_HASH = cd.ROW_KEY_HASH
WHERE rb.TABLE_SCHEMA = :p_schema
  AND rb.TABLE_NAME = :p_table
  AND rb.ROW_DATA_HASH != cd.ROW_DATA_HASH;

IF :v_change_count > 0 THEN
    SELECT STRING_AGG('OLD: ' || SUBSTR(ROW_DATA_JSON, 1, 100) || CHAR(10) ||
                     'NEW: ' || SUBSTR(NEW_JSON, 1, 100),
                     CHAR(10) || '---' || CHAR(10))
    INTO v_changes
    FROM (
        SELECT rb.ROW_DATA_JSON, cd.ROW_DATA_JSON AS NEW_JSON
        FROM TABLE_ROW_BASELINE rb
        INNER JOIN #CURRENT_DATA cd ON rb.ROW_KEY_HASH = cd.ROW_KEY_HASH
        WHERE rb.TABLE_SCHEMA = :p_schema
          AND rb.TABLE_NAME = :p_table
          AND rb.ROW_DATA_HASH != cd.ROW_DATA_HASH
        LIMIT 10
    );

    INSERT INTO MONITORING_LOG (
        TABLE_SCHEMA, TABLE_NAME, CHANGE_TYPE, CHANGE_DETAILS
    ) VALUES (
        :p_schema, :p_table, 'DATA_CHANGE',
        'ROWS MODIFIED (' || TO_VARCHAR(:v_change_count) || ' rows):' || CHAR(10) || COALESCE(:v_changes, 'No details available')
    );
END IF;

-- Update baseline with current data
DELETE FROM TABLE_ROW_BASELINE
WHERE TABLE_SCHEMA = :p_schema AND TABLE_NAME = :p_table;

INSERT INTO TABLE_ROW_BASELINE (TABLE_SCHEMA, TABLE_NAME, ROW_KEY_HASH, ROW_DATA_HASH, ROW_DATA_JSON)
SELECT :p_schema, :p_table, ROW_KEY_HASH, ROW_DATA_HASH, ROW_DATA_JSON
FROM #CURRENT_DATA;

-- Clean up
EXECUTE IMMEDIATE 'DROP TABLE #CURRENT_DATA';

INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
VALUES ('INFO', 'Completed detailed change detection for ' || :p_schema || '.' || :p_table);

END;

CREATE OR REPLACE PROCEDURE CHECK_SCHEMA_CHANGES()
LANGUAGE SQLSCRIPT
--SQL SECURITY DEFINER
AS
BEGIN
DECLARE CURSOR c_tables FOR
SELECT DISTINCT TABLE_SCHEMA, TABLE_NAME
FROM MONITORING_CONFIG
WHERE IS_ACTIVE = 'Y' AND MONITOR_SCHEMA_CHANGES = 'Y';


DECLARE v_schema NVARCHAR(256);
DECLARE v_table NVARCHAR(256);
DECLARE v_changes NCLOB;
DECLARE v_change_count INTEGER;

FOR cur_row AS c_tables DO
    v_schema := cur_row.TABLE_SCHEMA;
    v_table := cur_row.TABLE_NAME;
    v_changes := '';
    v_change_count := 0;
    
    -- Check for new columns
    SELECT STRING_AGG('NEW COLUMN: ' || COLUMN_NAME || ' (' || DATA_TYPE_NAME || ')', CHAR(10))
    INTO v_changes
    FROM (
        SELECT tc.COLUMN_NAME, tc.DATA_TYPE_NAME
        FROM TABLE_COLUMNS tc
        WHERE tc.SCHEMA_NAME = :v_schema 
          AND tc.TABLE_NAME = :v_table
          AND NOT EXISTS (
              SELECT 1 FROM TABLE_SCHEMA_BASELINE tsb
              WHERE tsb.TABLE_SCHEMA = tc.SCHEMA_NAME
                AND tsb.TABLE_NAME = tc.TABLE_NAME
                AND tsb.COLUMN_NAME = tc.COLUMN_NAME
          )
    );
    
    IF LENGTH(:v_changes) > 0 THEN
        v_change_count := v_change_count + 1;
    END IF;
    
    -- Check for removed columns
    SELECT CASE 
        WHEN LENGTH(:v_changes) > 0 THEN :v_changes || CHAR(10) || removed_cols
        ELSE removed_cols
    END INTO v_changes
    FROM (
        SELECT STRING_AGG('REMOVED COLUMN: ' || COLUMN_NAME, CHAR(10)) AS removed_cols
        FROM (
            SELECT tsb.COLUMN_NAME
            FROM TABLE_SCHEMA_BASELINE tsb
            WHERE tsb.TABLE_SCHEMA = :v_schema 
              AND tsb.TABLE_NAME = :v_table
              AND NOT EXISTS (
                  SELECT 1 FROM TABLE_COLUMNS tc
                  WHERE tc.SCHEMA_NAME = tsb.TABLE_SCHEMA
                    AND tc.TABLE_NAME = tsb.TABLE_NAME
                    AND tc.COLUMN_NAME = tsb.COLUMN_NAME
              )
        )
    );
    
    -- Check for column modifications
    SELECT CASE 
        WHEN LENGTH(:v_changes) > 0 THEN :v_changes || CHAR(10) || modified_cols
        ELSE modified_cols
    END INTO v_changes
    FROM (
        SELECT STRING_AGG('MODIFIED COLUMN: ' || tc.COLUMN_NAME || ' (Type: ' || 
                         tsb.DATA_TYPE_NAME || '->' || tc.DATA_TYPE_NAME || ')', CHAR(10)) AS modified_cols
        FROM TABLE_COLUMNS tc
        INNER JOIN TABLE_SCHEMA_BASELINE tsb
            ON tc.SCHEMA_NAME = tsb.TABLE_SCHEMA
           AND tc.TABLE_NAME = tsb.TABLE_NAME
           AND tc.COLUMN_NAME = tsb.COLUMN_NAME
        WHERE tc.SCHEMA_NAME = :v_schema 
          AND tc.TABLE_NAME = :v_table
          AND (tc.DATA_TYPE_NAME != tsb.DATA_TYPE_NAME
               OR tc.LENGTH != tsb.LENGTH
               OR tc.SCALE != tsb.SCALE
               OR tc.IS_NULLABLE != tsb.IS_NULLABLE)
    );
    
    -- If changes detected, log and trigger notification
    IF LENGTH(:v_changes) > 0 THEN
        INSERT INTO MONITORING_LOG (
            TABLE_SCHEMA, TABLE_NAME, CHANGE_TYPE, CHANGE_DETAILS
        ) VALUES (
            :v_schema, :v_table, 'SCHEMA_CHANGE', :v_changes
        );
        
        -- Refresh baseline for this table
        CALL INITIALIZE_TABLE_BASELINE(:v_schema, :v_table);
    END IF;
    
END FOR;


END;



CREATE OR REPLACE PROCEDURE CHECK_DATA_CHANGES()
LANGUAGE SQLSCRIPT
--SQL SECURITY DEFINER
AS
BEGIN
DECLARE CURSOR c_tables FOR
SELECT mc.TABLE_SCHEMA, mc.TABLE_NAME, mc.DATA_CHANGE_THRESHOLD
FROM MONITORING_CONFIG mc
WHERE mc.IS_ACTIVE = 'Y' AND mc.MONITOR_DATA_CHANGES = 'Y';


DECLARE v_schema NVARCHAR(256);
DECLARE v_table NVARCHAR(256);
DECLARE v_threshold INTEGER;
DECLARE v_current_count BIGINT;
DECLARE v_baseline_count BIGINT;
DECLARE v_sql NVARCHAR(20000);
DECLARE v_changes NCLOB;
DECLARE v_table_count INTEGER;
DECLARE v_detailed_tracking CHAR(1);

-- Log entry into procedure
INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
VALUES ('INFO', 'CHECK_DATA_CHANGES procedure started at ' || TO_VARCHAR(CURRENT_TIMESTAMP));

-- Check how many tables we should be monitoring
SELECT COUNT(*) INTO v_table_count
FROM MONITORING_CONFIG mc
WHERE mc.IS_ACTIVE = 'Y' AND mc.MONITOR_DATA_CHANGES = 'Y';

INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
VALUES ('INFO', 'Found ' || TO_VARCHAR(v_table_count) || ' tables configured for data change monitoring');

IF v_table_count = 0 THEN
    INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
    VALUES ('INFO', 'No tables configured for data monitoring - exiting CHECK_DATA_CHANGES');
    RETURN;
END IF;

FOR cur_row AS c_tables DO
    v_schema := cur_row.TABLE_SCHEMA;
    v_table := cur_row.TABLE_NAME;
    v_threshold := cur_row.DATA_CHANGE_THRESHOLD;
    
    INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
    VALUES ('INFO', 'Processing table: ' || v_schema || '.' || v_table || ' (threshold: ' || TO_VARCHAR(v_threshold) || ')');
    
    -- Check if detailed tracking is enabled
    SELECT COALESCE(TRACK_DETAILED_CHANGES, 'N') INTO v_detailed_tracking
    FROM MONITORING_CONFIG mc2
    WHERE mc2.TABLE_SCHEMA = :v_schema AND mc2.TABLE_NAME = :v_table;
    
    IF :v_detailed_tracking = 'Y' THEN
        -- Use detailed change detection
        INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
        VALUES ('INFO', 'Using detailed change detection for ' || v_schema || '.' || v_table);
        
        CALL CHECK_DETAILED_DATA_CHANGES(:v_schema, :v_table);
    ELSE
        -- Use standard row count detection
        INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
        VALUES ('INFO', 'Using basic row count detection for ' || v_schema || '.' || v_table);
        
        -- Get current row count
        v_sql := 'SELECT COUNT(*) FROM "' || :v_schema || '"."' || :v_table || '"';
        
        
        
        EXECUTE IMMEDIATE :v_sql INTO v_current_count;
        
        INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
        VALUES ('INFO', 'Current row count for ' || v_schema || '.' || v_table || ': ' || TO_VARCHAR(v_current_count));
        
        -- Get baseline values
        SELECT ROW_COUNT INTO v_baseline_count
        FROM TABLE_DATA_BASELINE 
        WHERE TABLE_SCHEMA = :v_schema AND TABLE_NAME = :v_table;
        
        INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
        VALUES ('INFO', 'Baseline for ' || v_schema || '.' || v_table || 
                ': rows=' || TO_VARCHAR(v_baseline_count) || 
                ', current_rows=' || TO_VARCHAR(v_current_count) ||
                ', delta=' || TO_VARCHAR(v_current_count - v_baseline_count));
        
        -- Check for significant changes
        IF ABS(:v_current_count - :v_baseline_count) >= :v_threshold THEN
            
            v_changes := 'Row count changed from ' || TO_VARCHAR(:v_baseline_count) || 
                        ' to ' || TO_VARCHAR(:v_current_count) || 
                        ' (Delta: ' || TO_VARCHAR(:v_current_count - :v_baseline_count) || ')';
            
            INSERT INTO MONITORING_LOG (
                TABLE_SCHEMA, TABLE_NAME, CHANGE_TYPE, CHANGE_DETAILS
            ) VALUES (
                :v_schema, :v_table, 'DATA_CHANGE', :v_changes
            );
            
            -- Update baseline
            UPDATE TABLE_DATA_BASELINE 
            SET ROW_COUNT = :v_current_count,
                LAST_UPDATE_TIME = CURRENT_TIMESTAMP,
                SNAPSHOT_DATE = CURRENT_TIMESTAMP
            WHERE TABLE_SCHEMA = :v_schema AND TABLE_NAME = :v_table;
            
            INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
            VALUES ('INFO', 'Updated baseline for ' || v_schema || '.' || v_table);
            
        ELSE
            INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
            VALUES ('INFO', 'No significant changes detected for ' || v_schema || '.' || v_table);
        END IF;
    END IF;
    
END FOR;

-- Log completion
INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
VALUES ('INFO', 'CHECK_DATA_CHANGES procedure completed at ' || TO_VARCHAR(CURRENT_TIMESTAMP));


END;


CREATE OR REPLACE PROCEDURE SEND_NOTIFICATIONS()
LANGUAGE SQLSCRIPT
SQL SECURITY DEFINER
AS
BEGIN
DECLARE CURSOR c_notifications FOR
SELECT
ml.LOG_ID,
ml.TABLE_SCHEMA,
ml.TABLE_NAME,
ml.CHANGE_TYPE,
ml.CHANGE_DETAILS,
ml.DETECTED_AT,
mc.SME_EMAIL,
mc.SME_NAME
FROM MONITORING_LOG ml
INNER JOIN MONITORING_CONFIG mc
ON ml.TABLE_SCHEMA = mc.TABLE_SCHEMA
AND ml.TABLE_NAME = mc.TABLE_NAME
WHERE ml.SME_NOTIFIED = 'N'
AND mc.IS_ACTIVE = 'Y'
AND ml.CHANGE_TYPE IN ('SCHEMA_CHANGE', 'DATA_CHANGE');


DECLARE v_log_id INTEGER;
DECLARE v_schema NVARCHAR(256);
DECLARE v_table NVARCHAR(256);
DECLARE v_change_type NVARCHAR(50);
DECLARE v_change_details NCLOB;
DECLARE v_detected_at TIMESTAMP;
DECLARE v_sme_emails NVARCHAR(2000);
DECLARE v_sme_name NVARCHAR(256);
DECLARE v_subject NVARCHAR(1000);
DECLARE v_body NCLOB;
DECLARE v_status NVARCHAR(500);
DECLARE v_notification_count INTEGER := 0;
DECLARE v_email_list NVARCHAR(2000);
DECLARE v_single_email NVARCHAR(500);
DECLARE v_semicolon_pos INTEGER;
DECLARE LV_RESULT INTEGER;

INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
VALUES ('INFO', 'Starting notification process with multi-email support');

FOR cur_row AS c_notifications DO
    v_log_id := cur_row.LOG_ID;
    v_schema := cur_row.TABLE_SCHEMA;
    v_table := cur_row.TABLE_NAME;
    v_change_type := cur_row.CHANGE_TYPE;
    v_change_details := cur_row.CHANGE_DETAILS;
    v_detected_at := cur_row.DETECTED_AT;
    v_sme_emails := cur_row.SME_EMAIL;
    v_sme_name := cur_row.SME_NAME;
    
    -- Build email subject
    v_subject := 'Alert: ' || :v_change_type || ' detected in ' || :v_table;
    
    -- Build email body
    v_body := 'Dear ' || COALESCE(:v_sme_name, 'Subject Matter Expert') || ',' || CHAR(10) || CHAR(10) ||
              'This is an automated notification from the HANA Universal Table Monitor.' || CHAR(10) || CHAR(10) ||
              'ALERT DETAILS:' || CHAR(10) ||
              '- Table: ' || :v_table || CHAR(10) ||
              '- Change Type: ' || :v_change_type || CHAR(10) ||
              '- Detected At: ' || TO_VARCHAR(:v_detected_at) || CHAR(10) || CHAR(10) ||
              'CHANGE DETAILS:' || CHAR(10) ||
              :v_change_details || CHAR(10) || CHAR(10) ||
              'Please review these changes and take appropriate action if necessary.' || CHAR(10) || CHAR(10) ||
              'This is an automated message from the HANA Table Monitoring System.';
    
    -- Parse semicolon-separated email list - SIMPLE APPROACH
    v_email_list := TRIM(:v_sme_emails);
    
    -- Handle single email (no semicolon)
    IF LOCATE(:v_email_list, ';') = 0 THEN
        -- Single email - send directly
        IF LENGTH(:v_email_list) > 0 AND LOCATE(:v_email_list, '@') > 0 THEN
            
            
            
           
call sys.statisticsserver_sendmail_dev ('SMTP_SERVER', PORT, 'FROM_EMAIL',v_email_list,v_subject ,v_body , LV_RESULT);
               
            
            
            v_status := 'SUCCESS';
            v_notification_count := v_notification_count + 1;
            
            INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
            VALUES ('INFO', 'Sent notification to: ' || :v_email_list);
            
        END IF;
    ELSE
        -- Multiple emails - parse and send to each
        WHILE LENGTH(:v_email_list) > 0 DO
            v_semicolon_pos := LOCATE(:v_email_list, ';');
            
            IF :v_semicolon_pos = 0 THEN
                -- Last email in list
                v_single_email := TRIM(:v_email_list);
                v_email_list := '';
            ELSE
                -- Extract current email
                v_single_email := TRIM(SUBSTR(:v_email_list, 1, :v_semicolon_pos - 1));
                v_email_list := TRIM(SUBSTR(:v_email_list, :v_semicolon_pos + 1));
            END IF;
            
            -- Send email to this recipient if valid
            IF LENGTH(:v_single_email) > 0 AND LOCATE(:v_single_email, '@') > 0 THEN
                
                
                
                
call sys.statisticsserver_sendmail_dev ('SMTP_SERVER', 25, 'FROM_EMAIL',v_single_email,v_subject ,v_body , LV_RESULT);
               
             
                
                v_status := 'SUCCESS';
                v_notification_count := v_notification_count + 1;
                
                INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
                VALUES ('INFO', 'Sent notification to: ' || :v_single_email);
                
            END IF;
            
        END WHILE;
    END IF;
    
    -- Update notification status
    UPDATE MONITORING_LOG 
    SET SME_NOTIFIED = 'Y',
        NOTIFICATION_STATUS = 'MULTI_EMAIL_SUCCESS'
    WHERE LOG_ID = :v_log_id;
    
END FOR;

INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
VALUES ('INFO', 'Multi-email notification process completed. Sent ' || TO_VARCHAR(v_notification_count) || ' notifications');


END;

CREATE OR REPLACE PROCEDURE RUN_TABLE_MONITORING()
LANGUAGE SQLSCRIPT
--SQL SECURITY DEFINER
AS
BEGIN



-- Log start of monitoring cycle
INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
VALUES ('INFO', 'Starting monitoring cycle at ' || TO_VARCHAR(CURRENT_TIMESTAMP));

-- Check schema changes
INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
VALUES ('INFO', 'About to call CHECK_SCHEMA_CHANGES');

CALL CHECK_SCHEMA_CHANGES();

INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
VALUES ('INFO', 'Completed CHECK_SCHEMA_CHANGES, about to call CHECK_DATA_CHANGES');

-- Check data changes  
CALL CHECK_DATA_CHANGES();

INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
VALUES ('INFO', 'Completed CHECK_DATA_CHANGES, about to call SEND_NOTIFICATIONS');

-- Send notifications
CALL SEND_NOTIFICATIONS();

INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
VALUES ('INFO', 'Completed SEND_NOTIFICATIONS');

-- Log successful run
INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
VALUES ('INFO', 'Monitoring cycle completed successfully at ' || TO_VARCHAR(CURRENT_TIMESTAMP));


END;



CREATE OR REPLACE PROCEDURE REMOVE_TABLE_FROM_MONITORING(
IN p_schema NVARCHAR(256),
IN p_table NVARCHAR(256)
)
LANGUAGE SQLSCRIPT
--SQL SECURITY DEFINER
AS
BEGIN
-- Deactivate monitoring
UPDATE MONITORING_CONFIG
SET IS_ACTIVE = 'N'
WHERE TABLE_SCHEMA = :p_schema AND TABLE_NAME = :p_table;


INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
VALUES ('INFO', 'Deactivated monitoring for ' || :p_schema || '.' || :p_table);


END;

CREATE OR REPLACE PROCEDURE CLEANUP_MONITORING_DATA(
IN p_days_to_keep INTEGER DEFAULT 90
)
LANGUAGE SQLSCRIPT
--SQL SECURITY DEFINER
AS
BEGIN
DECLARE v_deleted_logs INTEGER;
DECLARE v_deleted_baselines INTEGER;


-- Clean up old monitoring logs
DELETE FROM MONITORING_LOG 
WHERE DETECTED_AT < ADD_DAYS(CURRENT_TIMESTAMP, -:p_days_to_keep);

v_deleted_logs := ::ROWCOUNT;

-- Clean up old row baselines for inactive tables
DELETE FROM TABLE_ROW_BASELINE trb
WHERE NOT EXISTS (
    SELECT 1 FROM MONITORING_CONFIG mc 
    WHERE mc.TABLE_SCHEMA = trb.TABLE_SCHEMA 
      AND mc.TABLE_NAME = trb.TABLE_NAME 
      AND mc.IS_ACTIVE = 'Y'
);

v_deleted_baselines := ::ROWCOUNT;

-- Log cleanup results
INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
VALUES ('INFO', 'Cleanup completed: Deleted ' || TO_VARCHAR(:v_deleted_logs) || 
        ' log entries and ' || TO_VARCHAR(:v_deleted_baselines) || ' baseline entries');


END;

CREATE OR REPLACE PROCEDURE ANALYZE_TABLE_FOR_MONITORING(
IN p_schema NVARCHAR(256),
IN p_table NVARCHAR(256)
)
LANGUAGE SQLSCRIPT
--SQL SECURITY DEFINER
AS
BEGIN
DECLARE v_row_count BIGINT;
DECLARE v_column_count INTEGER;
DECLARE v_has_pk CHAR(1) := 'N';
DECLARE v_table_exists INTEGER;
DECLARE v_recommendation NVARCHAR(1000);
DECLARE v_suggested_sample DECIMAL(5,2);


-- Check if table exists
SELECT COUNT(*) INTO v_table_exists
FROM TABLES WHERE SCHEMA_NAME = :p_schema AND TABLE_NAME = :p_table;

IF v_table_exists = 0 THEN
    INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
    VALUES ('INFO', 'Table ' || :p_schema || '.' || :p_table || ' does not exist');
    RETURN;
END IF;

-- Get row count and column count
EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM "' || :p_schema || '"."' || :p_table || '"' INTO v_row_count;

SELECT COUNT(*) INTO v_column_count
FROM TABLE_COLUMNS WHERE SCHEMA_NAME = :p_schema AND TABLE_NAME = :p_table;

-- Check for primary key
SELECT CASE WHEN COUNT(*) > 0 THEN 'Y' ELSE 'N' END INTO v_has_pk
 FROM SYS.CONSTRAINTS 
WHERE SCHEMA_NAME = :p_schema AND TABLE_NAME = :p_table AND IS_PRIMARY_KEY = 'TRUE';

-- Generate recommendations
IF :v_row_count <= 1000 THEN
    v_recommendation := 'EXCELLENT for detailed monitoring. Small table, enable full tracking.';
    v_suggested_sample := 100.00;
ELSEIF :v_row_count <= 10000 THEN
    v_recommendation := 'GOOD for detailed monitoring. Medium table, consider full tracking.';
    v_suggested_sample := 100.00;
ELSEIF :v_row_count <= 100000 THEN
    v_recommendation := 'MODERATE for detailed monitoring. Large table, use sampling.';
    v_suggested_sample := 20.00;
ELSE
    v_recommendation := 'NOT RECOMMENDED for detailed monitoring. Use basic monitoring only.';
    v_suggested_sample := 5.00;
END IF;

IF :v_has_pk = 'N' THEN
    v_recommendation := :v_recommendation || ' WARNING: No primary key found.';
END IF;

-- Log analysis results
INSERT INTO MONITORING_LOG (CHANGE_TYPE, CHANGE_DETAILS)
VALUES ('INFO', 
    'TABLE ANALYSIS: ' || :p_schema || '.' || :p_table || CHAR(10) ||
    'Rows: ' || TO_VARCHAR(:v_row_count) || CHAR(10) ||
    'Columns: ' || TO_VARCHAR(:v_column_count) || CHAR(10) ||
    'Has Primary Key: ' || :v_has_pk || CHAR(10) ||
    'Suggested Sample %: ' || TO_VARCHAR(:v_suggested_sample) || CHAR(10) ||
    'Recommendation: ' || :v_recommendation);


END;


CREATE OR REPLACE VIEW V_MONITORING_STATUS AS
SELECT
mc.TABLE_SCHEMA,
mc.TABLE_NAME,
mc.SME_EMAIL,
mc.SME_NAME,
mc.IS_ACTIVE,
mc.CHECK_FREQUENCY_MINUTES,
mc.TRACK_DETAILED_CHANGES,
mc.MAX_ROWS_FOR_DETAILED_TRACKING,
mc.SAMPLE_PERCENTAGE,
tdb.ROW_COUNT AS CURRENT_ROW_COUNT,
tdb.LAST_UPDATE_TIME,
COUNT(ml.LOG_ID) AS TOTAL_ALERTS,
MAX(ml.DETECTED_AT) AS LAST_ALERT,
COUNT(trb.BASELINE_ID) AS DETAILED_ROWS_TRACKED
FROM MONITORING_CONFIG mc
LEFT JOIN TABLE_DATA_BASELINE tdb
ON mc.TABLE_SCHEMA = tdb.TABLE_SCHEMA
AND mc.TABLE_NAME = tdb.TABLE_NAME
LEFT JOIN MONITORING_LOG ml
ON mc.TABLE_SCHEMA = ml.TABLE_SCHEMA
AND mc.TABLE_NAME = ml.TABLE_NAME
AND ml.CHANGE_TYPE IN ('SCHEMA_CHANGE', 'DATA_CHANGE')
LEFT JOIN TABLE_ROW_BASELINE trb
ON mc.TABLE_SCHEMA = trb.TABLE_SCHEMA
AND mc.TABLE_NAME = trb.TABLE_NAME
GROUP BY
mc.TABLE_SCHEMA, mc.TABLE_NAME, mc.SME_EMAIL, mc.SME_NAME,
mc.IS_ACTIVE, mc.CHECK_FREQUENCY_MINUTES, mc.TRACK_DETAILED_CHANGES,
mc.MAX_ROWS_FOR_DETAILED_TRACKING, mc.SAMPLE_PERCENTAGE,
tdb.ROW_COUNT, tdb.LAST_UPDATE_TIME;


CREATE OR REPLACE VIEW V_RECENT_ALERTS AS
SELECT
ml.DETECTED_AT,
ml.TABLE_SCHEMA,
ml.TABLE_NAME,
ml.CHANGE_TYPE,
CASE
WHEN LENGTH(ml.CHANGE_DETAILS) > 200
THEN SUBSTR(ml.CHANGE_DETAILS, 1, 200) || '…'
ELSE ml.CHANGE_DETAILS
END AS CHANGE_SUMMARY,
ml.SME_NOTIFIED,
ml.NOTIFICATION_STATUS,
mc.SME_EMAIL,
mc.SME_NAME,
mc.TRACK_DETAILED_CHANGES
FROM MONITORING_LOG ml
INNER JOIN MONITORING_CONFIG mc
ON ml.TABLE_SCHEMA = mc.TABLE_SCHEMA
AND ml.TABLE_NAME = mc.TABLE_NAME
WHERE ml.CHANGE_TYPE IN ('SCHEMA_CHANGE', 'DATA_CHANGE')
AND ml.DETECTED_AT >= ADD_DAYS(CURRENT_TIMESTAMP, -7)
ORDER BY ml.DETECTED_AT DESC;


CREATE OR REPLACE VIEW V_CHANGE_DETAILS AS
SELECT
ml.LOG_ID,
ml.DETECTED_AT,
ml.TABLE_SCHEMA,
ml.TABLE_NAME,
ml.CHANGE_TYPE,
ml.CHANGE_DETAILS,
ml.SME_NOTIFIED,
mc.SME_EMAIL,
CASE
WHEN ml.CHANGE_DETAILS LIKE '%NEW ROWS ADDED%' THEN 'INSERTS'
WHEN ml.CHANGE_DETAILS LIKE '%ROWS DELETED%' THEN 'DELETES'
WHEN ml.CHANGE_DETAILS LIKE '%ROWS MODIFIED%' THEN 'UPDATES'
WHEN ml.CHANGE_DETAILS LIKE '%Row count changed%' THEN 'COUNT_CHANGE'
WHEN ml.CHANGE_DETAILS LIKE '%COLUMN%' THEN 'SCHEMA_CHANGE'
ELSE 'OTHER'
END AS CHANGE_CATEGORY
FROM MONITORING_LOG ml
INNER JOIN MONITORING_CONFIG mc
ON ml.TABLE_SCHEMA = mc.TABLE_SCHEMA
AND ml.TABLE_NAME = mc.TABLE_NAME
WHERE ml.CHANGE_TYPE IN ('SCHEMA_CHANGE', 'DATA_CHANGE')
ORDER BY ml.DETECTED_AT DESC;
