-- ----------------------------------------------------------------
-- MPP regression tests for the WarehousePG-specific parts of hll.
--
-- Upstream postgresql-hll is single-node, so nothing upstream covers
-- either the hll_set_max_sparse() dispatch or hll aggregates running
-- as partial/final aggregation across segments.
--
-- Every assertion below is phrased so its output does not depend on
-- the number of segments, so the expected file is stable on any
-- cluster topology.
-- ----------------------------------------------------------------

SELECT hll_set_output_version(1);

-- ----------------------------------------------------------------
-- 1. hll_set_max_sparse() must reach every segment.
--
-- The function is declared IMMUTABLE, so "+ 0*gp_segment_id" stops
-- the planner constant-folding the probe away, and gp_dist_random()
-- forces execution on the segments. The probe returns each segment's
-- *previous* value, which is what reveals whether the dispatch from
-- the coordinator landed.
-- ----------------------------------------------------------------

-- baseline: all segments sit on the -1 default
SELECT count(DISTINCT old) = 1 AS all_segments_agree, max(old) AS value_seen
FROM (SELECT hll_set_max_sparse(-1 + 0*gp_segment_id) AS old
        FROM gp_dist_random('gp_id')) s;

-- set on the coordinator only; every segment must observe 777
SELECT hll_set_max_sparse(777);
SELECT count(DISTINCT old) = 1 AS all_segments_agree, max(old) AS value_seen
FROM (SELECT hll_set_max_sparse(777 + 0*gp_segment_id) AS old
        FROM gp_dist_random('gp_id')) s;

-- and again with a second distinct value, to catch a stale-value pass
SELECT hll_set_max_sparse(1234);
SELECT count(DISTINCT old) = 1 AS all_segments_agree, max(old) AS value_seen
FROM (SELECT hll_set_max_sparse(1234 + 0*gp_segment_id) AS old
        FROM gp_dist_random('gp_id')) s;

SELECT hll_set_max_sparse(-1);

-- ----------------------------------------------------------------
-- 2. The dispatched value must actually change the representation
--    chosen on the segments -- identically on all of them.
--    Reading the value back only proves a variable moved; this
--    proves it takes effect. hll_type: 3 = SPARSE, 4 = FULL.
-- ----------------------------------------------------------------

CREATE TABLE mpp_hll_small (id int) DISTRIBUTED BY (id);
INSERT INTO mpp_hll_small SELECT generate_series(1,360);

-- sparse disabled -> FULL on every segment
SELECT hll_set_max_sparse(0);
SELECT count(DISTINCT t) = 1 AS all_segments_same_type, max(t) AS hll_type_seen
FROM (SELECT hll_type(hll_add_agg(hll_hash_integer(id),11,5,0,1)) AS t
        FROM mpp_hll_small GROUP BY gp_segment_id) s;

-- sparse preferred -> SPARSE on every segment
SELECT hll_set_max_sparse(4096);
SELECT count(DISTINCT t) = 1 AS all_segments_same_type, max(t) AS hll_type_seen
FROM (SELECT hll_type(hll_add_agg(hll_hash_integer(id),11,5,0,1)) AS t
        FROM mpp_hll_small GROUP BY gp_segment_id) s;

-- the encoding change must not move the answer
SELECT hll_set_max_sparse(0);
CREATE TEMP TABLE mpp_c_full AS
  SELECT hll_cardinality(hll_add_agg(hll_hash_integer(id),11,5,0,1))::bigint c
    FROM mpp_hll_small DISTRIBUTED REPLICATED;
SELECT hll_set_max_sparse(4096);
CREATE TEMP TABLE mpp_c_sparse AS
  SELECT hll_cardinality(hll_add_agg(hll_hash_integer(id),11,5,0,1))::bigint c
    FROM mpp_hll_small DISTRIBUTED REPLICATED;
SELECT hll_set_max_sparse(-1);
SELECT (SELECT c FROM mpp_c_full) = (SELECT c FROM mpp_c_sparse) AS cardinality_agrees;

-- ----------------------------------------------------------------
-- 3. Aggregates under partial/final aggregation across segments.
-- ----------------------------------------------------------------

CREATE TABLE mpp_hll_dist (id int, grp int) DISTRIBUTED BY (id);
INSERT INTO mpp_hll_dist SELECT g, g % 7 FROM generate_series(1,50000) g;
CREATE TABLE mpp_hll_rep (id int, grp int) DISTRIBUTED REPLICATED;
INSERT INTO mpp_hll_rep SELECT g, g % 7 FROM generate_series(1,50000) g;

-- distributed (two-phase) must equal replicated (single-segment), bitwise
SELECT (SELECT hll_add_agg(hll_hash_integer(id)) FROM mpp_hll_dist)
     = (SELECT hll_add_agg(hll_hash_integer(id)) FROM mpp_hll_rep)
       AS dist_equals_single;

-- multiphase on vs off must agree bitwise
SET gp_enable_multiphase_agg = on;
CREATE TEMP TABLE mpp_r_multi AS
  SELECT hll_add_agg(hll_hash_integer(id)) h FROM mpp_hll_dist DISTRIBUTED REPLICATED;
SET gp_enable_multiphase_agg = off;
CREATE TEMP TABLE mpp_r_single AS
  SELECT hll_add_agg(hll_hash_integer(id)) h FROM mpp_hll_dist DISTRIBUTED REPLICATED;
RESET gp_enable_multiphase_agg;
SELECT (SELECT h FROM mpp_r_multi) = (SELECT h FROM mpp_r_single) AS multiphase_agrees;

-- hll_union_agg over per-group hlls must equal one global hll_add_agg
CREATE TABLE mpp_hll_grp AS
  SELECT grp, hll_add_agg(hll_hash_integer(id)) AS h
    FROM mpp_hll_dist GROUP BY grp DISTRIBUTED BY (grp);
SELECT (SELECT hll_union_agg(h) FROM mpp_hll_grp)
     = (SELECT hll_add_agg(hll_hash_integer(id)) FROM mpp_hll_dist)
       AS union_agg_matches_global;

-- Smoke check on accuracy. The bitwise assertions above are what
-- prove MPP correctness; this only catches a grossly wrong estimate.
-- The bound is deliberately loose: at the default log2m=11 (2048
-- registers) HLL's 1-sigma error is 1.04/sqrt(2048) = 2.3%, and this
-- dataset lands ~5.1% low (47431 vs 50000), which is ordinary. A real
-- breakage shows up orders of magnitude out, not a few percent.
SELECT abs(hll_cardinality(hll_add_agg(hll_hash_integer(id))) - 50000)
         < 50000 * 0.10 AS within_10_percent
FROM mpp_hll_dist;

DROP TABLE mpp_hll_grp;
DROP TABLE mpp_hll_rep;
DROP TABLE mpp_hll_dist;
DROP TABLE mpp_hll_small;
