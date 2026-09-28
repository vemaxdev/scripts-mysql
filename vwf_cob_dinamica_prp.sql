-- vwf_cob_dinamica_prp
-- Uma linha por dia, do 1o dia do mes atual ate o ultimo dia do mes atual + 2,
-- com a quantidade de PN planejados e realizados em cada dia
-- (base pbi.vwf_cob_dinamica_pn).
--
-- Colunas:
--   qtd_planejado : PN com planejado = data
--   qtd_proj      : PN com planejado = data e status do mes da data = 'WIP'
--                   (mesma regra de proj_mN em pbi.vwf_indicadores_dinamica)
--   qtd_realizado : PN com status do mes da data = 'ITEM COBERTO' cuja ultima
--                   NF para a Embraer (SD2, cliente IN (6,7,8)) no periodo foi
--                   emitida na data; PN coberto so por estoque (sem NF no
--                   periodo) nao entra

CREATE OR REPLACE ALGORITHM=UNDEFINED DEFINER=`vemax`@`%` SQL SECURITY DEFINER VIEW `pbi`.`vwf_cob_dinamica_prp` AS

WITH RECURSIVE dias AS (
  SELECT CAST(DATE_FORMAT(CURDATE(), '%Y-%m-01') AS DATE) AS data
  UNION ALL
  SELECT data + INTERVAL 1 DAY
  FROM dias
  WHERE data < LAST_DAY(CURDATE() + INTERVAL 2 MONTH)
),
cal AS (
  SELECT
    D.data,
    CAST(DATE_FORMAT(D.data, '%Y-%m-01') AS DATE) AS mes_ref,
    TIMESTAMPDIFF(MONTH, DATE_FORMAT(CURDATE(), '%Y-%m-01'), D.data) AS mes_idx
  FROM dias D
),
-- ultima NF emitida para a Embraer por PN dentro do calendario (mesmo filtro
-- SD2 x ordem_fabricacao usado em pbi.vwf_cobertura_pn)
nf AS (
  SELECT
    ODF.pn,
    CAST(MAX(SD2.emissao) AS DATE) AS data_nf
  FROM manufatura.totvs_sd2 SD2
  JOIN manufatura.ordem_fabricacao ODF ON ODF.`of` = SD2.`of`
  WHERE SD2.cliente IN (6, 7, 8)
    AND SD2.numpedcomp = SUBSTRING_INDEX(ODF.oc_linha, '/', 1)
    AND SD2.itempedcom <> ''
    AND CAST(SD2.itempedcom AS UNSIGNED) = CAST(SUBSTRING_INDEX(ODF.oc_linha, '/', -1) AS UNSIGNED)
    AND SD2.emissao >= DATE_FORMAT(CURDATE(), '%Y-%m-01')
    AND SD2.emissao < LAST_DAY(CURDATE() + INTERVAL 2 MONTH) + INTERVAL 1 DAY
  GROUP BY ODF.pn
),
-- agrega os PN primeiro (join interno) e so depois liga ao calendario:
-- com pbi.vwf_cob_dinamica_pn direto no LEFT JOIN o MySQL (8.0.46) deixa de
-- aplicar o filtro EXISTS (poack LIDO/NFE) da view e conta PN a mais
planejado AS (
  SELECT
    C.data,
    COUNT(*) AS qtd_planejado,
    CAST(SUM(
      CASE C.mes_idx
        WHEN 0 THEN P.status_m0
        WHEN 1 THEN P.status_m1
        WHEN 2 THEN P.status_m2
      END = 'WIP'
    ) AS SIGNED) AS qtd_proj
  FROM pbi.vwf_cob_dinamica_pn P
  JOIN cal C ON C.data = DATE(P.planejado)
  GROUP BY C.data
),
realizado AS (
  SELECT
    C.data,
    CAST(SUM(
      CASE C.mes_idx
        WHEN 0 THEN P.status_m0
        WHEN 1 THEN P.status_m1
        WHEN 2 THEN P.status_m2
      END = 'ITEM COBERTO'
    ) AS SIGNED) AS qtd_realizado
  FROM pbi.vwf_cob_dinamica_pn P
  JOIN nf N ON N.pn = P.pn
  JOIN cal C ON C.data = N.data_nf
  GROUP BY C.data
)
SELECT
  C.data,
  C.mes_ref,
  C.mes_idx,
  DAYOFWEEK(C.data) AS dia_semana,
  CASE WHEN DAYOFWEEK(C.data) IN (1, 7) THEN 1 ELSE 0 END AS fim_de_semana,
  COALESCE(PL.qtd_planejado, 0) AS qtd_planejado,
  COALESCE(PL.qtd_proj, 0) AS qtd_proj,
  COALESCE(R.qtd_realizado, 0) AS qtd_realizado
FROM cal C
LEFT JOIN planejado PL ON PL.data = C.data
LEFT JOIN realizado R ON R.data = C.data
ORDER BY C.data;
