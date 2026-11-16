CREATE SCHEMA shop;
CREATE TABLE shop.customers (
    id          bigserial PRIMARY KEY,
    email       text NOT NULL UNIQUE,
    name        text,
    is_active   boolean NOT NULL DEFAULT true,
    metadata    jsonb,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE shop.orders (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id  bigint NOT NULL REFERENCES shop.customers(id),
    total        numeric(12,2) NOT NULL,
    tags         text[],
    placed_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX orders_customer_idx ON shop.orders(customer_id);

INSERT INTO shop.customers (email, name, metadata)
SELECT 'user' || g || '@example.com', 'User ' || g, jsonb_build_object('tier', (g % 3))
FROM generate_series(1, 5000) g;

INSERT INTO shop.orders (customer_id, total, tags)
SELECT (g % 5000) + 1, round((random() * 500)::numeric, 2), ARRAY['web', 'promo']
FROM generate_series(1, 20000) g;
