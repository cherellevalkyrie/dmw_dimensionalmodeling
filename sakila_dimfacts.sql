-- ============================================================
-- OPTION B: fact_rental_lifecycle
-- Sakila Data Warehouse - Operations Team
-- ============================================================
-- GRAIN
--   One row per rental transaction (one row per rental_id).
--
-- FACT TYPE
--   Accumulating snapshot fact. A rental begins when checked out and
--   reaches a completed lifecycle when returned. Open rentals remain
--   in the fact with a CURRENTLY_OUT status.
--
-- SPECIAL REQUIREMENT: RENTALS NOT YET RETURNED
--   return_date is nullable in the source. The fact does NOT store a
--   NULL foreign key. Instead:
--     * return_date_key = 0 means "Not returned"
--     * status_key = 3 means CURRENTLY_OUT
--
-- EXISTING DIMENSIONS REUSED
--   dim_time, dim_movie, dim_store, dim_staff.
--
-- NEW DIMENSIONS
--   dim_customer and dim_rental_status.
--
-- ACTOR NOTE
--   dim_actor + bridge_film_actor are intentionally not joined to this
--   fact. Joining actors would multiply rental rows because a film can
--   have many actors and would break the one-row-per-rental grain.
--
-- MEASURES
--   rental_count             = 1; additive.
--   rental_duration_days     = actual days out, or days out to the
--                              warehouse snapshot date for open rentals.
--   expected_duration_days   = film.rental_duration.
--   overdue_days             = max(days out - expected duration, 0).
--   is_late                  = 1 only for returned rentals that exceeded
--                              the allowed rental duration.
--   is_currently_out         = 1 when return_date IS NULL.
-- ============================================================

CREATE DATABASE IF NOT EXISTS sakila_dw;
USE sakila_dw;

-- ============================================================
-- 0. SELF-CONTAINED DIMENSIONS
-- If your demo warehouse already contains these dimensions with
-- the same structures, skip/reuse those existing tables instead.
-- ============================================================

DROP TABLE IF EXISTS fact_rental_lifecycle;
DROP TABLE IF EXISTS dim_rental_status;
DROP TABLE IF EXISTS dim_customer;
DROP TABLE IF EXISTS dim_time;
DROP TABLE IF EXISTS dim_movie;
DROP TABLE IF EXISTS dim_store;
DROP TABLE IF EXISTS dim_staff;

CREATE TABLE dim_time (
    time_key       INT NOT NULL,
    full_date      DATE NOT NULL,
    year_num       SMALLINT NOT NULL,
    quarter_num    TINYINT NOT NULL,
    month_num      TINYINT NOT NULL,
    month_name     VARCHAR(12) NOT NULL,
    week_num       TINYINT NOT NULL,
    day_num        TINYINT NOT NULL,
    day_name       VARCHAR(12) NOT NULL,
    PRIMARY KEY (time_key),
    UNIQUE KEY uq_dim_time_date (full_date)
) ENGINE=InnoDB;

CREATE TABLE dim_movie (
    movie_key          INT NOT NULL AUTO_INCREMENT,
    film_id            SMALLINT UNSIGNED NOT NULL,
    title              VARCHAR(128) NOT NULL,
    release_year       YEAR NULL,
    rental_duration    TINYINT UNSIGNED NOT NULL,
    rental_rate        DECIMAL(4,2) NOT NULL,
    replacement_cost   DECIMAL(5,2) NOT NULL,
    rating             VARCHAR(10) NULL,
    PRIMARY KEY (movie_key),
    UNIQUE KEY uq_dim_movie_film (film_id)
) ENGINE=InnoDB;

CREATE TABLE dim_store (
    store_key      INT NOT NULL AUTO_INCREMENT,
    store_id       TINYINT UNSIGNED NOT NULL,
    address        VARCHAR(50) NOT NULL,
    district       VARCHAR(20) NOT NULL,
    city           VARCHAR(50) NOT NULL,
    country        VARCHAR(50) NOT NULL,
    PRIMARY KEY (store_key),
    UNIQUE KEY uq_dim_store_store (store_id)
) ENGINE=InnoDB;

CREATE TABLE dim_staff (
    staff_key      INT NOT NULL AUTO_INCREMENT,
    staff_id       TINYINT UNSIGNED NOT NULL,
    first_name     VARCHAR(45) NOT NULL,
    last_name      VARCHAR(45) NOT NULL,
    store_id       TINYINT UNSIGNED NOT NULL,
    active         BOOLEAN NOT NULL,
    PRIMARY KEY (staff_key),
    UNIQUE KEY uq_dim_staff_staff (staff_id)
) ENGINE=InnoDB;

CREATE TABLE dim_customer (
    customer_key   INT NOT NULL AUTO_INCREMENT,
    customer_id    SMALLINT UNSIGNED NOT NULL,
    first_name     VARCHAR(45) NOT NULL,
    last_name      VARCHAR(45) NOT NULL,
    email          VARCHAR(50) NULL,
    store_id       TINYINT UNSIGNED NOT NULL,
    active         BOOLEAN NOT NULL,
    PRIMARY KEY (customer_key),
    UNIQUE KEY uq_dim_customer_customer (customer_id)
) ENGINE=InnoDB;

CREATE TABLE dim_rental_status (
    status_key          TINYINT NOT NULL,
    status_code         VARCHAR(30) NOT NULL,
    status_description  VARCHAR(100) NOT NULL,
    PRIMARY KEY (status_key),
    UNIQUE KEY uq_status_code (status_code)
) ENGINE=InnoDB;

INSERT INTO dim_rental_status
    (status_key, status_code, status_description)
VALUES
    (1, 'RETURNED_ON_TIME', 'Rental was returned within the allowed rental duration'),
    (2, 'RETURNED_LATE',    'Rental was returned after the allowed rental duration'),
    (3, 'CURRENTLY_OUT',    'Rental has not yet been returned');

-- ============================================================
-- 1. POPULATE DIMENSIONS
-- ============================================================

-- Special time member used for "not returned".
INSERT INTO dim_time
    (time_key, full_date, year_num, quarter_num, month_num,
     month_name, week_num, day_num, day_name)
VALUES
    (0, '1900-01-01', 1900, 1, 1, 'Unknown', 1, 1, 'Unknown');


INSERT INTO dim_time
    (time_key, full_date, year_num, quarter_num, month_num,
     month_name, week_num, day_num, day_name)
WITH RECURSIVE date_bounds AS (
    SELECT
        DATE(MIN(rental_date)) AS min_date,
        GREATEST(
            DATE(MAX(rental_date)),
            COALESCE(DATE(MAX(return_date)), DATE(MAX(rental_date))),
            DATE(MAX(last_update))
        ) AS max_date
    FROM sakila.rental
),
calendar AS (
    SELECT min_date AS d, max_date
    FROM date_bounds
    UNION ALL
    SELECT DATE_ADD(d, INTERVAL 1 DAY), max_date
    FROM calendar
    WHERE d < max_date
)
SELECT
    CAST(DATE_FORMAT(d, '%Y%m%d') AS UNSIGNED),
    d,
    YEAR(d),
    QUARTER(d),
    MONTH(d),
    MONTHNAME(d),
    WEEK(d, 3),
    DAY(d),
    DAYNAME(d)
FROM calendar
WHERE d <> '1900-01-01';

INSERT INTO dim_movie
    (film_id, title, release_year, rental_duration,
     rental_rate, replacement_cost, rating)
SELECT
    film_id,
    title,
    release_year,
    rental_duration,
    rental_rate,
    replacement_cost,
    rating
FROM sakila.film;

INSERT INTO dim_store
    (store_id, address, district, city, country)
SELECT
    s.store_id,
    a.address,
    a.district,
    c.city,
    co.country
FROM sakila.store s
JOIN sakila.address a
  ON s.address_id = a.address_id
JOIN sakila.city c
  ON a.city_id = c.city_id
JOIN sakila.country co
  ON c.country_id = co.country_id;

INSERT INTO dim_staff
    (staff_id, first_name, last_name, store_id, active)
SELECT
    staff_id,
    first_name,
    last_name,
    store_id,
    active
FROM sakila.staff;

INSERT INTO dim_customer
    (customer_id, first_name, last_name, email, store_id, active)
SELECT
    customer_id,
    first_name,
    last_name,
    email,
    store_id,
    active
FROM sakila.customer;

-- ============================================================
-- 2. FACT TABLE
-- ============================================================

CREATE TABLE fact_rental_lifecycle (
    rental_lifecycle_key   BIGINT NOT NULL AUTO_INCREMENT,
    rental_id              INT NOT NULL,

    rental_date_key        INT NOT NULL,
    return_date_key        INT NOT NULL,
    movie_key              INT NOT NULL,
    store_key              INT NOT NULL,
    staff_key              INT NOT NULL,
    customer_key           INT NOT NULL,
    status_key             TINYINT NOT NULL,

    rental_duration_days   INT NOT NULL,
    expected_duration_days INT NOT NULL,
    overdue_days           INT NOT NULL,

    is_late                TINYINT NOT NULL,
    is_currently_out       TINYINT NOT NULL,
    rental_count           TINYINT NOT NULL DEFAULT 1,

    source_last_update     DATETIME NOT NULL,

    PRIMARY KEY (rental_lifecycle_key),
    UNIQUE KEY uq_fact_rental (rental_id),

    KEY idx_fact_rental_date (rental_date_key),
    KEY idx_fact_return_date (return_date_key),
    KEY idx_fact_movie (movie_key),
    KEY idx_fact_store (store_key),
    KEY idx_fact_staff (staff_key),
    KEY idx_fact_customer (customer_key),
    KEY idx_fact_status (status_key),

    CONSTRAINT fk_fact_rental_date
        FOREIGN KEY (rental_date_key) REFERENCES dim_time(time_key),
    CONSTRAINT fk_fact_return_date
        FOREIGN KEY (return_date_key) REFERENCES dim_time(time_key),
    CONSTRAINT fk_fact_movie
        FOREIGN KEY (movie_key) REFERENCES dim_movie(movie_key),
    CONSTRAINT fk_fact_store
        FOREIGN KEY (store_key) REFERENCES dim_store(store_key),
    CONSTRAINT fk_fact_staff
        FOREIGN KEY (staff_key) REFERENCES dim_staff(staff_key),
    CONSTRAINT fk_fact_customer
        FOREIGN KEY (customer_key) REFERENCES dim_customer(customer_key),
    CONSTRAINT fk_fact_status
        FOREIGN KEY (status_key) REFERENCES dim_rental_status(status_key)
) ENGINE=InnoDB;

-- ============================================================
-- 3. LOAD FACT
-- ============================================================
-- The source data is a static Sakila snapshot. Therefore open
-- rentals use the source's latest rental last_update date as the
-- warehouse "as-of" date. This keeps the assignment reproducible
-- instead of comparing 2005 data with the computer's current date.

SET @warehouse_as_of_date = (
    SELECT DATE(MAX(last_update))
    FROM sakila.rental
);

INSERT INTO fact_rental_lifecycle
(
    rental_id,
    rental_date_key,
    return_date_key,
    movie_key,
    store_key,
    staff_key,
    customer_key,
    status_key,
    rental_duration_days,
    expected_duration_days,
    overdue_days,
    is_late,
    is_currently_out,
    rental_count,
    source_last_update
)
SELECT
    r.rental_id,

    CAST(DATE_FORMAT(DATE(r.rental_date), '%Y%m%d') AS UNSIGNED),

    CASE
        WHEN r.return_date IS NULL THEN 0
        ELSE CAST(DATE_FORMAT(DATE(r.return_date), '%Y%m%d') AS UNSIGNED)
    END,

    dm.movie_key,
    ds.store_key,
    dst.staff_key,
    dc.customer_key,

    CASE
        WHEN r.return_date IS NULL THEN 3
        WHEN DATEDIFF(DATE(r.return_date), DATE(r.rental_date))
             > CAST(f.rental_duration AS SIGNED) THEN 2
        ELSE 1
    END,

    DATEDIFF(
        CASE
            WHEN r.return_date IS NULL THEN @warehouse_as_of_date
            ELSE DATE(r.return_date)
        END,
        DATE(r.rental_date)
    ),

    f.rental_duration,

    GREATEST(
        DATEDIFF(
            CASE
                WHEN r.return_date IS NULL THEN @warehouse_as_of_date
                ELSE DATE(r.return_date)
            END,
            DATE(r.rental_date)
        ) - CAST(f.rental_duration AS SIGNED),
        0
    ),

    CASE
        WHEN r.return_date IS NOT NULL
         AND DATEDIFF(DATE(r.return_date), DATE(r.rental_date))
             > f.rental_duration
        THEN 1
        ELSE 0
    END,

    CASE
        WHEN r.return_date IS NULL THEN 1
        ELSE 0
    END,

    1,

    r.last_update

FROM sakila.rental r
JOIN sakila.inventory i
  ON r.inventory_id = i.inventory_id
JOIN sakila.film f
  ON i.film_id = f.film_id
JOIN dim_movie dm
  ON dm.film_id = f.film_id
JOIN dim_store ds
  ON ds.store_id = i.store_id
JOIN dim_staff dst
  ON dst.staff_id = r.staff_id
JOIN dim_customer dc
  ON dc.customer_id = r.customer_id;

-- ============================================================
-- PART 3: VALIDATION
-- ============================================================

-- 3.1 Grain check:
-- fact row count must equal source rental row count.
SELECT
    (SELECT COUNT(*) FROM sakila.rental) AS source_row_count,
    (SELECT COUNT(*) FROM fact_rental_lifecycle) AS fact_row_count,
    (SELECT COUNT(*) FROM fact_rental_lifecycle)
      - (SELECT COUNT(*) FROM sakila.rental) AS row_count_difference;

SELECT
    CASE
        WHEN (SELECT COUNT(*) FROM sakila.rental)
           = (SELECT COUNT(*) FROM fact_rental_lifecycle)
        THEN 'PASS'
        ELSE 'FAIL'
    END AS grain_check;

-- 3.2 Option B reconciliation:
-- COUNT(DISTINCT rental_id) must equal COUNT(*).
SELECT
    COUNT(DISTINCT rental_id) AS distinct_rental_id_count,
    COUNT(*) AS fact_row_count,
    COUNT(*) - COUNT(DISTINCT rental_id) AS duplicate_difference
FROM fact_rental_lifecycle;

SELECT
    CASE
        WHEN COUNT(DISTINCT rental_id) = COUNT(*)
        THEN 'PASS'
        ELSE 'FAIL'
    END AS reconciliation_check
FROM fact_rental_lifecycle;

-- 3.3 No NULL foreign keys.
SELECT
    SUM(rental_date_key IS NULL) AS null_rental_date_keys,
    SUM(return_date_key IS NULL) AS null_return_date_keys,
    SUM(movie_key IS NULL) AS null_movie_keys,
    SUM(store_key IS NULL) AS null_store_keys,
    SUM(staff_key IS NULL) AS null_staff_keys,
    SUM(customer_key IS NULL) AS null_customer_keys,
    SUM(status_key IS NULL) AS null_status_keys
FROM fact_rental_lifecycle;

SELECT
    CASE
        WHEN SUM(rental_date_key IS NULL)
           + SUM(return_date_key IS NULL)
           + SUM(movie_key IS NULL)
           + SUM(store_key IS NULL)
           + SUM(staff_key IS NULL)
           + SUM(customer_key IS NULL)
           + SUM(status_key IS NULL) = 0
        THEN 'PASS'
        ELSE 'FAIL'
    END AS null_foreign_key_check
FROM fact_rental_lifecycle;

-- Additional integrity checks.
SELECT
    CASE
        WHEN SUM(rental_count <> 1) = 0 THEN 'PASS'
        ELSE 'FAIL'
    END AS rental_count_check
FROM fact_rental_lifecycle;

SELECT
    CASE
        WHEN SUM(
            (is_currently_out = 1 AND status_key <> 3)
            OR
            (is_currently_out = 1 AND return_date_key <> 0)
        ) = 0
        THEN 'PASS'
        ELSE 'FAIL'
    END AS open_rental_status_check
FROM fact_rental_lifecycle;

SELECT
    CASE
        WHEN SUM(is_currently_out = 0 AND status_key = 3) = 0
        THEN 'PASS'
        ELSE 'FAIL'
    END AS returned_rental_status_check
FROM fact_rental_lifecycle;

-- ============================================================
-- PART 4: THREE BUSINESS QUESTIONS
-- ============================================================

-- QUESTION 1
-- How long do rentals stay out, and how often do they come back
-- late, by store?
SELECT
    ds.store_id,
    ds.city,
    ds.country,
    COUNT(*) AS total_rentals,
    ROUND(AVG(f.rental_duration_days), 2) AS avg_days_out,
    MAX(f.rental_duration_days) AS max_days_out,
    SUM(f.is_late) AS late_returns,
    ROUND(100.0 * SUM(f.is_late) / COUNT(*), 2) AS late_return_pct,
    SUM(f.is_currently_out) AS currently_out
FROM fact_rental_lifecycle f
JOIN dim_store ds
  ON f.store_key = ds.store_key
GROUP BY
    ds.store_id,
    ds.city,
    ds.country
ORDER BY
    late_return_pct DESC,
    avg_days_out DESC;

-- QUESTION 2
-- Which movies have the highest late-return rate?
-- Minimum 10 rentals prevents a single-rental movie from dominating
-- the ranking.
SELECT
    dm.film_id,
    dm.title,
    COUNT(*) AS total_rentals,
    SUM(f.is_late) AS late_returns,
    ROUND(100.0 * SUM(f.is_late) / COUNT(*), 2) AS late_return_pct,
    ROUND(AVG(f.rental_duration_days), 2) AS avg_days_out,
    SUM(f.is_currently_out) AS currently_out
FROM fact_rental_lifecycle f
JOIN dim_movie dm
  ON f.movie_key = dm.movie_key
GROUP BY
    dm.film_id,
    dm.title
HAVING COUNT(*) >= 10
ORDER BY
    late_return_pct DESC,
    late_returns DESC,
    dm.title
LIMIT 10;

-- QUESTION 3
-- What rentals are still out, and how long have they been out?
SELECT
    f.rental_id,
    dc.customer_id,
    CONCAT(dc.first_name, ' ', dc.last_name) AS customer_name,
    dm.film_id,
    dm.title,
    ds.store_id,
    ds.city,
    f.rental_duration_days AS days_out,
    f.expected_duration_days,
    f.overdue_days,
    f.is_currently_out
FROM fact_rental_lifecycle f
JOIN dim_customer dc
  ON f.customer_key = dc.customer_key
JOIN dim_movie dm
  ON f.movie_key = dm.movie_key
JOIN dim_store ds
  ON f.store_key = ds.store_key
WHERE f.is_currently_out = 1
ORDER BY
    f.overdue_days DESC,
    f.rental_duration_days DESC,
    f.rental_id;

-- Optional current-out summary.
SELECT
    COUNT(*) AS rentals_currently_out,
    SUM(f.overdue_days > 0) AS currently_overdue,
    ROUND(AVG(f.rental_duration_days), 2) AS avg_days_out,
    MAX(f.rental_duration_days) AS max_days_out
FROM fact_rental_lifecycle f
WHERE f.is_currently_out = 1;

-- ============================================================
-- PART 1: BUS MATRIX FOR OPTION B
-- ============================================================
-- Business process: Rental lifecycle
--
-- Grain: one row per rental_id
--
-- Dimensions:
--   Time       -> checkout/rental date and return date
--   Movie      -> film rented
--   Store      -> store holding the inventory item
--   Staff      -> staff member who processed the rental
--   Customer   -> customer who rented the film
--   Status     -> returned on time / returned late / currently out
--
-- Facts:
--   rental_count            additive
--   rental_duration_days    additive; AVG is preferred for duration
--   expected_duration_days  additive mathematically; AVG is preferred
--   overdue_days            additive
--   is_late                 additive as a count of late rentals
--   is_currently_out        additive as a count of open rentals
--
-- Existing dimensions reused:
--   dim_time, dim_movie, dim_store, dim_staff
--
-- New dimensions:
--   dim_customer, dim_rental_status
--
-- dim_actor + bridge_film_actor are not directly attached to this fact
-- because that would create multiple fact rows per rental.
--
-- ============================================================
-- END OF OPTION B
-- ============================================================
