-- For https://github.com/aws-samples/aws-database-migration-samples/tree/master/PostgreSQL/sampledb/v1

-- Events Dimension
CREATE TABLE dimEvents
(
  event_key        SERIAL PRIMARY KEY,
  sport_type_name  varchar(50),
  home_team        varchar(50),
  away_team        varchar(50),
  location_name    varchar(50),
  start_date_time  timestamp,
  start_date       date,
  sold_out         smallint
);

INSERT INTO dimEvents (event_key,sport_type_name,home_team,away_team,location_name,start_date_time,start_date,sold_out)
SELECT se.id              AS event_key,
       se.sport_type_name AS sport_type_name,
       hst.name           AS home_team,
       ast.name           AS away_team,
       sl.name            AS location_name,
       start_date_time    AS start_date_time,
       start_date         AS start_date,
       sold_out           AS sold_out
FROM sporting_event se
INNER JOIN sport_team hst    ON home_team_id=hst.id
INNER JOIN sport_team ast    ON away_team_id=ast.id
INNER JOIN sport_location sl ON location_id=sl.id;

-- Date Dimension
CREATE TABLE dimDate
(
  date_key integer NOT NULL PRIMARY KEY,
  date date,
  year smallint,
  quarter smallint,
  month smallint,
  day smallint,
  week smallint,
  is_weekend boolean
);

INSERT INTO dimDate (date_key, date, year, quarter, month, day, week, is_weekend)
SELECT DISTINCT(TO_CHAR(transaction_date_time :: DATE, 'yyyyMMDD')::integer) AS date_key,
    date(transaction_date_time)                                              AS date,
    EXTRACT(year FROM transaction_date_time)                                 AS year,
    EXTRACT(quarter FROM transaction_date_time)                              AS quarter,
    EXTRACT(month FROM transaction_date_time)                                AS month,
    EXTRACT(day FROM transaction_date_time)                                  AS day,
    EXTRACT(week FROM transaction_date_time)                                 AS week,
    CASE WHEN
     EXTRACT(ISODOW FROM transaction_date_time) IN (6, 7)
    THEN true ELSE false END                                                 AS is_weekend
FROM ticket_purchase_hist;

-- Seat Dimension
CREATE TABLE dimSeat
(
  seat_key              varchar(50) NOT NULL PRIMARY KEY,
  location_name         varchar(50),
  location_city         varchar(50),
  seat_level            smallint,
  seat_section          varchar(50),
  seat_row              varchar(50),
  seat                  varchar(50),
  type_name             varchar(50),
  type_description      varchar(150),
  type_relative_quality smallint
);

INSERT INTO dimSeat (seat_key, location_name, location_city, seat_level, seat_section, seat_row, seat, type_name, type_description, type_relative_quality)
SELECT DISTINCT(
         CONCAT_WS('-', sport_location_id, seat_level, seat_section, seat_row, seat)
       )                   AS seat_key,
       sl.name             AS location_name,
       sl.city             AS location_city,
       seat_level          AS seat_level,
       seat_section        AS seat_section,
       seat_row            AS seat_row,
       seat                AS seat,
       seat_type           AS type_name,
       st.description      AS type_description,
       st.relative_quality AS type_relative_quality
FROM ( SELECT sport_location_id, seat_level, seat_section, seat_row, seat, seat_type[array_length(seat_type, 1)]
  FROM ( SELECT sport_location_id, seat_level, seat_section, seat_row, seat, array_agg(seat_type) AS seat_type
         FROM seat
         Group BY sport_location_id, seat_level, seat_section, seat_row, seat
) a) x
INNER JOIN seat_type st      ON seat_type=st.name
INNER JOIN sport_location sl ON sport_location_id=sl.id;

-- Fact Table
CREATE TABLE factPurchase
(
  purchase_key       SERIAL PRIMARY KEY,
  date_key           INT REFERENCES dimDate(date_key),
  event_key          INT REFERENCES dimEvents(event_key),
  seat_key           varchar(50) REFERENCES dimSeat(seat_key),
  person_key         INT REFERENCES Person(id),
  original_price     decimal(5,2),
  purchase_count     INT,
  last_price         decimal(5,2)
);

INSERT INTO factPurchase (purchase_key, date_key, event_key, seat_key, person_key, original_price, purchase_count, last_price)
SELECT id                                                                AS purchase_key,
       TO_CHAR(date[array_length(date, 1)] :: DATE, 'yyyyMMDD')::integer AS date_key,
       sporting_event_id                                                 AS event_key,
       seat_key                                                          AS seat_key,
       ticketholder_id                                                   AS person_key,
       original_price                                                    AS original_price,
       purchase_count                                                    AS purchase_count,
       last_price[array_length(last_price, 1)]                           AS last_price
FROM (
  SELECT st.id                                                    AS id,
         sporting_event_id,
         ticket_price                                             AS original_price,
         array_agg(hist.purchase_price)                           AS last_price,
         CONCAT_WS('-',
           sport_location_id,
           seat_level,
           seat_section,
           seat_row,
           seat)                                             AS seat_key,
         count(hist.sporting_event_ticket_id)                     AS purchase_count,
         ticketholder_id,
         array_agg(hist.transaction_date_time)                    AS date
  FROM sporting_event_ticket st
  INNER JOIN ticket_purchase_hist hist ON st.id=hist.sporting_event_ticket_id
  GROUP BY st.id
) a
ORDER BY date_key;

-- Cube using the fact table

-- Without Joins

SELECT date_key, event_key, seat_key,
       COUNT(*)            AS purchase_count,
       SUM(original_price) AS original_price
FROM factPurchase
GROUP BY CUBE(date_key, event_key, seat_key);

-- With Joins

SELECT dd.month            AS month,
       de.sport_type_name  AS sport_type_name,
       de.location_name    AS location_name,
       COUNT(*)            AS tickets_sold,
       SUM(original_price) AS total_sales
FROM factPurchase fp
INNER JOIN dimDate dd   ON fp.date_key=dd.date_key
INNER JOIN dimEvents de ON fp.event_key=de.event_key
GROUP BY CUBE(dd.month, de.sport_type_name, de.location_name)
ORDER BY dd.month, de.sport_type_name, de.location_name;

-- Compare it with the Cube from original Table

SELECT EXTRACT(month FROM date[array_length(date, 1)] :: DATE) AS month,
       se.sport_type_name                                      AS sport_type_name,
       sl.name                                                 AS location_name,
       COUNT(*)                                                AS tickets_sold,
       SUM(original_price)                                     AS total_sales
FROM ( SELECT st.id                                                   AS id,
             sporting_event_id,
             ticket_price                                             AS original_price,
             sport_location_id,
             array_agg(hist.transaction_date_time)                    AS date
       FROM sporting_event_ticket st
       LEFT JOIN ticket_purchase_hist hist ON st.id=hist.sporting_event_ticket_id
       GROUP BY st.id
       ORDER BY date ) a
INNER JOIN sporting_event se ON se.id=a.sporting_event_id
INNER JOIN sport_location sl ON se.location_id=sl.id
WHERE EXTRACT(month FROM date[array_length(date, 1)] :: DATE) IS NOT NULL
GROUP BY CUBE(month, sport_type_name, location_name)
ORDER BY month, sport_type_name, location_name;
