## ScrollSense - Data Management Assignment 1

This repository contains the SQL scripts and supporting files for the ScrollSense
Data Management Assignment 1.

The database is created from scratch using the provided Python data generator,
followed by the schema, queries, views and transaction demonstrations.

---

## Project Structure


- data_generator.py - Generates the database data.
- schema.sql - Creates the database schema and constraints.
- queries.sql - Contains the queries for Deliverable F.
- views.sql - Contains the five views for Deliverable G.1.
- transactions.sql - Contains the transaction demonstrations for Deliverable G.3.
- Scrollsense_generated.db - Generated SQLite database.
- README.md

## Requirements


The following are required:

Python 3
SQLite
DBeaver (recommended for running and inspecting the database)

No external Python packages are required unless specified in the generator
file.

## Generate the database

python3 data_generator.py --out Scrollsense_generated.db --scale 1

## Open the Database

Open Scrollsense_generated.db in DBeaver as a SQLite database.

Make sure that all SQL scripts are connected to this same database.

Before running the assignment queries, it is useful to check that the database
contains data:

SELECT COUNT(*) FROM users;

The result should be greater than zero.

## Run schema.sql

Open schema.sql in DBeaver and execute the schema statements.

The schema creates the tables, constraints, indexes and other database
objects required by the assignment.

If the database was generated using generator.py with the schema already
applied, this step may already have been performed by the generator.

## Run queries.sql

Open queries.sql in DBeaver.

The queries for Deliverable F should be executed one at a time.

For each query:

Select only that query.
Execute it using Cmd + Enter.
Record the result.
Record the number of returned rows.
Record the first five rows where required.
Record the execution time.

## Important

Do not execute all the queries together when collecting the results.
Some queries are demonstrations of different SQL behaviours, and executing
multiple statements together can make it difficult to identify the individual
result and runtime.

## Run views.sql

Open views.sql in DBeaver and create the five views:

v_public_profile
v_video_current_state
v_creator_tier_current
v_video_daily_engagement
v_turn_cost

The views can then be tested using:

SELECT * FROM v_public_profile LIMIT 10;
SELECT * FROM v_video_current_state LIMIT 10;
SELECT * FROM v_creator_tier_current LIMIT 10;
SELECT * FROM v_video_daily_engagement LIMIT 10;
SELECT * FROM v_turn_cost LIMIT 10;

For testing and debugging, execute the statements one at a time.

The verified row counts are:

v_public_profile          4580
v_video_current_state     20000
v_creator_tier_current    750
v_video_daily_engagement  216486
v_turn_cost               6989

## Run transactions.sql

The transaction demonstrations should also be executed carefully and
individually.

## T1 - Retraction

T1 demonstrates that a failure between two related operations can be rolled
back so that the database does not remain partially updated.

The transaction should be run statement by statement:

BEGIN TRANSACTION
        ↓
first operation
        ↓
deliberate failure
        ↓
ROLLBACK
        ↓
verification query

Do not commit the transaction after the deliberate failure.

## T2 - Moderation Decision

T2 requires two separate connections to the same SQLite database.

Connection 1 starts a transaction and inserts a moderation decision but does
not commit it.

Connection 2 then queries the same table. The uncommitted change should not
be visible from Connection 2.

WAL mode can be checked using:

PRAGMA journal_mode;

The expected result is:

wal
Important

For the transaction demonstrations, do not execute the entire file at once.
Run the transaction statements in the intended order so that the intermediate
states and failures can be observed.


- When testing individual queries or transaction steps, use:

Cmd + Enter

on the selected statement rather than running the entire SQL script.

This is especially important for:

Deliverable F queries
View creation/testing
T1 transaction steps
T2 two-connection experiment

Running everything together can cause transaction-state errors or make the
individual results difficult to distinguish.
