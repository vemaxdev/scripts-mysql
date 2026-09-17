-- vwf_indicadores_dinamica
-- Indicadores consolidados (uma unica linha) da cobertura dinamica por PN,
-- calculados sobre pbi.vwf_cob_dinamica_pn (uma linha por part number).
--
-- Meses: m0 = mes atual, m1 = mes atual + 1, m2 = mes atual + 2.
--
-- Colunas:
--   total      : total de PN/linhas na view
--   cob_mN     : PN com status_mN = 'ITEM COBERTO'
--   proj_mN    : PN com status_mN = 'WIP' e planejado dentro do mes N
--                (data de cobertura prevista em pbi.vwf_cobertura_pn)
--   per_mN     : (cob_mN + proj_mN) / total, em escala 0-100
--   peso_mN    : per_mN ponderado (m0 = 60%, m1 = 35%, m2 = 5%)
--   per_total  : peso_m0 + peso_m1 + peso_m2 (indicador final, escala 0-100)

CREATE OR REPLACE ALGORITHM=UNDEFINED DEFINER=`vemax`@`%` SQL SECURITY DEFINER VIEW `pbi`.`vwf_indicadores_dinamica` AS

SELECT
  P.total,
  P.cob_m0,
  P.cob_m1,
  P.cob_m2,
  P.proj_m0,
  P.proj_m1,
  P.proj_m2,
  P.per_m0,
  P.per_m1,
  P.per_m2,
  ROUND(P.per_m0 * 0.60, 2) AS peso_m0,
  ROUND(P.per_m1 * 0.35, 2) AS peso_m1,
  ROUND(P.per_m2 * 0.05, 2) AS peso_m2,
  ROUND(
      ROUND(P.per_m0 * 0.60, 2)
    + ROUND(P.per_m1 * 0.35, 2)
    + ROUND(P.per_m2 * 0.05, 2)
  , 2) AS per_total
FROM (
  SELECT
    I.total,
    I.cob_m0,
    I.cob_m1,
    I.cob_m2,
    I.proj_m0,
    I.proj_m1,
    I.proj_m2,
    ROUND((I.cob_m0 + I.proj_m0) * 100 / NULLIF(I.total, 0), 2) AS per_m0,
    ROUND((I.cob_m1 + I.proj_m1) * 100 / NULLIF(I.total, 0), 2) AS per_m1,
    ROUND((I.cob_m2 + I.proj_m2) * 100 / NULLIF(I.total, 0), 2) AS per_m2
  FROM (
    SELECT
      COUNT(*) AS total,
      CAST(COALESCE(SUM(D.status_m0 = 'ITEM COBERTO'), 0) AS SIGNED) AS cob_m0,
      CAST(COALESCE(SUM(D.status_m1 = 'ITEM COBERTO'), 0) AS SIGNED) AS cob_m1,
      CAST(COALESCE(SUM(D.status_m2 = 'ITEM COBERTO'), 0) AS SIGNED) AS cob_m2,
      CAST(COALESCE(SUM(
        D.status_m0 = 'WIP'
        AND DATE_FORMAT(D.planejado, '%Y-%m-01') = DATE_FORMAT(CURDATE(), '%Y-%m-01')
      ), 0) AS SIGNED) AS proj_m0,
      CAST(COALESCE(SUM(
        D.status_m1 = 'WIP'
        AND DATE_FORMAT(D.planejado, '%Y-%m-01') = DATE_FORMAT(CURDATE() + INTERVAL 1 MONTH, '%Y-%m-01')
      ), 0) AS SIGNED) AS proj_m1,
      CAST(COALESCE(SUM(
        D.status_m2 = 'WIP'
        AND DATE_FORMAT(D.planejado, '%Y-%m-01') = DATE_FORMAT(CURDATE() + INTERVAL 2 MONTH, '%Y-%m-01')
      ), 0) AS SIGNED) AS proj_m2
    FROM pbi.vwf_cob_dinamica_pn D
  ) I
) P;
