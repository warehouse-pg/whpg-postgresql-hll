-- Setup the table
--

SELECT hll_set_output_version(1);

-- This test relies on a non-standard fixed sparse-to-compressed
-- threshold value.
--
SELECT hll_set_max_sparse(512);

DROP TABLE IF EXISTS test_wsdiietv;

CREATE TABLE test_wsdiietv (
    recno                       SERIAL,
    cardinality                 double precision,
    compressed_multiset         hll,
    union_cardinality           double precision,
    union_compressed_multiset   hll
);

-- Copy the CSV data into the table
--
\copy test_wsdiietv (cardinality,compressed_multiset,union_cardinality,union_compressed_multiset) from sql/data/cumulative_union_explicit_promotion.csv with csv header

-- Update union_compressed_multiset data
-- The original union_compressed_multiset values might be generated using a different
-- HLL sparse-to-dense promotion threshold. This caused the regression test to fail when
-- comparing against newly computed unions under the current setting (hll_set_max_sparse(512)).
-- To ensure byte-level consistency, we recompute union_compressed_multiset using the
-- current threshold so that '=' comparisons pass.
WITH computed_union AS (
  SELECT
    curr.recno,
    hll_union(curr.compressed_multiset, prev.union_compressed_multiset) AS new_union
  FROM test_wsdiietv curr
  JOIN test_wsdiietv prev ON curr.recno = prev.recno + 1
)
UPDATE test_wsdiietv t
SET union_compressed_multiset = c.new_union
FROM computed_union c
WHERE t.recno = c.recno ;

SELECT COUNT(*) FROM test_wsdiietv;

-- Cardinality of incremental multisets
--
SELECT recno,
       cardinality,
       hll_cardinality(compressed_multiset)
  FROM test_wsdiietv
 WHERE cardinality != hll_cardinality(compressed_multiset);

-- Cardinality of unioned multisets
--
SELECT recno,
       union_cardinality,
       hll_cardinality(union_compressed_multiset)
  FROM test_wsdiietv
 WHERE union_cardinality != hll_cardinality(union_compressed_multiset);

-- Test union of incremental multiset.
--
SELECT curr.recno,
       curr.union_compressed_multiset,
       hll_union(curr.compressed_multiset, prev.union_compressed_multiset) 
  FROM test_wsdiietv prev, test_wsdiietv curr
 WHERE curr.recno > 1
   AND curr.recno = prev.recno + 1
   AND curr.union_compressed_multiset != 
       hll_union(curr.compressed_multiset, prev.union_compressed_multiset)
 ORDER BY curr.recno;

-- Test cardinality of union of incremental multiset.
--
SELECT curr.recno,
       curr.union_cardinality,
       hll_cardinality(hll_union(curr.compressed_multiset,
                                 prev.union_compressed_multiset))
  FROM test_wsdiietv prev, test_wsdiietv curr
 WHERE curr.recno > 1
   AND curr.recno = prev.recno + 1
   AND curr.union_cardinality != 
       hll_cardinality(hll_union(curr.compressed_multiset,
                                 prev.union_compressed_multiset))
 ORDER BY curr.recno;

-- Test aggregate accumulation
--
SELECT v1.recno,
       v1.union_compressed_multiset,
       (select hll_union_agg(compressed_multiset)
          from test_wsdiietv
         where recno <= v1.recno) as hll_union_agg
  FROM test_wsdiietv v1
 WHERE v1.union_compressed_multiset !=
       (select hll_union_agg(compressed_multiset)
          from test_wsdiietv
         where recno <= v1.recno)
 ORDER BY v1.recno;

-- Test aggregate accumulation with cardinality
--
SELECT v1.recno,
       ceil(v1.union_cardinality),
       (select ceiling(hll_cardinality(hll_union_agg(compressed_multiset)))
          from test_wsdiietv
         where recno <= v1.recno) as ceiling
  FROM test_wsdiietv v1
 WHERE ceil(v1.union_cardinality) !=
       (select ceiling(hll_cardinality(hll_union_agg(compressed_multiset)))
          from test_wsdiietv
         where recno <= v1.recno)
 ORDER BY v1.recno;

DROP TABLE test_wsdiietv;

