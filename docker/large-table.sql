-- Optional: a 400,000-row table for trying the row-count estimate (tables of 100k+ rows show "~N rows" and are
-- only counted on request). Not part of the seed, because the integration tests expect the seeded table list.
--   docker exec -i tableroad-test-mysql-1 mysql -uroot -ptableroad tableroad < docker/large-table.sql
-- Remove it again before running the tests: DROP TABLE big_log;
DROP TABLE IF EXISTS big_log;
CREATE TABLE big_log (
    id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    kind        VARCHAR(20) NOT NULL,
    payload     VARCHAR(100),
    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    KEY big_log_kind (kind)
) COMMENT = 'Large table for row-count estimate testing';
SET SESSION cte_max_recursion_depth = 500000;
INSERT INTO big_log (kind, payload)
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 400000)
SELECT ELT(i % 3 + 1, 'login', 'update', 'delete'), CONCAT('payload ', i) FROM n;
-- Fresh statistics, so the estimate is realistic straight away.
ANALYZE TABLE big_log;
