CREATE TABLE customers (
    id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    email       VARCHAR(255) NOT NULL UNIQUE,
    name        VARCHAR(255),
    is_active   TINYINT(1) NOT NULL DEFAULT 1,
    metadata    JSON,
    created_at  DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
);
CREATE TABLE orders (
    id           BIGINT AUTO_INCREMENT PRIMARY KEY,
    customer_id  BIGINT NOT NULL,
    total        DECIMAL(12,2) NOT NULL,
    status       ENUM('pending','paid','shipped') NOT NULL DEFAULT 'pending',
    placed_at    DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    KEY orders_customer_idx (customer_id),
    CONSTRAINT orders_customer_fk FOREIGN KEY (customer_id) REFERENCES customers(id)
);

-- Cross-join digits instead of a recursive CTE: MySQL caps recursion at 1000 by default
-- and MariaDB doesn't support cte_max_recursion_depth, so this works on both.
-- Not TEMPORARY: MySQL cannot reference a temporary table more than once in a query.
CREATE TABLE digits (d INT);
INSERT INTO digits VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);

INSERT INTO customers (email, name, metadata)
SELECT CONCAT('user', n, '@example.com'), CONCAT('User ', n), JSON_OBJECT('tier', n % 3)
FROM (SELECT a.d + b.d * 10 + c.d * 100 + e.d * 1000 + 1 AS n
      FROM digits a, digits b, digits c, digits e WHERE e.d < 5) nums;

INSERT INTO orders (customer_id, total, status)
SELECT (n % 5000) + 1, ROUND(RAND() * 500, 2), ELT((n % 3) + 1, 'pending', 'paid', 'shipped')
FROM (SELECT a.d + b.d * 10 + c.d * 100 + e.d * 1000 + 1 AS n
      FROM digits a, digits b, digits c, digits e) nums;

DROP TABLE digits;
