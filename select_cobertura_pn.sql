-- SELECT que reproduz a logica do cobertura.py (passos 1 a 4).
-- Ainda NAO e uma view - primeiro validar o resultado.

WITH cfg_islands AS (
  -- agrupa execucoes consecutivas (por id) com o mesmo data_periodo_final,
  -- para diferenciar um periodo "de verdade" de um reprocessamento isolado
  SELECT data_periodo_final, MIN(id) AS min_id, MAX(id) AS max_id, COUNT(*) AS cnt
  FROM (
    SELECT id, data_periodo_final,
           ROW_NUMBER() OVER (ORDER BY id)
           - ROW_NUMBER() OVER (PARTITION BY data_periodo_final ORDER BY id) AS grp
    FROM manufatura.controle_processamento_cobertura
  ) t
  GROUP BY data_periodo_final, grp
),

cfg_atual AS (
  SELECT data_periodo_inicial, data_periodo_final
  FROM manufatura.controle_processamento_cobertura
  ORDER BY id DESC
  LIMIT 1
),

cfg_ilha_atual AS (
  SELECT min_id, max_id FROM cfg_islands ORDER BY max_id DESC LIMIT 1
),

cfg_anterior AS (
  -- periodo anterior real: a ilha mais recente antes do periodo atual com
  -- pelo menos 10 execucoes seguidas (descarta ruido de reprocessamento)
  SELECT i.data_periodo_final
  FROM cfg_islands i
  JOIN cfg_ilha_atual c ON i.max_id < c.min_id
  WHERE i.cnt >= 10
  ORDER BY i.max_id DESC
  LIMIT 1
),

CFG AS (
  SELECT
    a.data_periodo_inicial,
    -- novo limite inferior: dia seguinte ao fim do periodo anterior (sem overlap)
    DATE_ADD(p.data_periodo_final, INTERVAL 1 DAY) AS data_periodo_inicial_ajustado
  FROM cfg_atual a
  CROSS JOIN cfg_anterior p
),

-- Passo 2/3: notas reais na SD2 (via ordem_fabricacao, nao pn_extrato_cobertura)
-- numpedcomp/itempedcom precisam bater com as duas partes de oc_linha (ex:
-- "906245296/00010"), senao pega linha da SD2 do mesmo `of` de outro pedido/item.
-- cliente IN (6,7,8) = Embraer (mesmo filtro de vw_totvs_sd2_embraer); sem isso,
-- o match por of+numpedcomp+itempedcom pode coincidir com nota de outro cliente
notas_sd2 AS (
  SELECT
    PNAT.pn,
    ODF.`of`,
    SD2.emissao,
    MAX(SD2.quantidade) AS quantidade
  FROM pn_cobertura_atual PNAT
  JOIN ordem_fabricacao ODF ON ODF.pn = PNAT.pn
  JOIN CFG ON 1 = 1
  JOIN totvs_sd2 SD2
    ON SD2.`of` = ODF.`of`
   AND SD2.numpedcomp = SUBSTRING_INDEX(ODF.oc_linha, '/', 1)
   AND SD2.itempedcom <> ''
   AND CAST(SD2.itempedcom AS UNSIGNED) = CAST(SUBSTRING_INDEX(ODF.oc_linha, '/', -1) AS UNSIGNED)
   AND SD2.cliente IN (6, 7, 8)
   AND SD2.emissao BETWEEN CFG.data_periodo_inicial_ajustado AND LAST_DAY(CFG.data_periodo_inicial)
  GROUP BY PNAT.pn, ODF.`of`, SD2.emissao
),

notas_sd2_acumulado AS (
  SELECT
    pn,
    `of`,
    emissao,
    quantidade,
    SUM(quantidade) OVER (
      PARTITION BY pn
      ORDER BY emissao, `of`
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS qtde_acumulada
  FROM notas_sd2
),

-- Passo 3: primeira nota que cobre o saldo (se houver)
notas_sd2_rank AS (
  SELECT
    NA.pn,
    NA.`of`,
    NA.emissao,
    NA.qtde_acumulada,
    ROW_NUMBER() OVER (PARTITION BY NA.pn ORDER BY NA.emissao, NA.`of`) AS rn
  FROM notas_sd2_acumulado NA
  JOIN pn_cobertura_atual PNAT ON PNAT.pn = NA.pn
  WHERE NA.qtde_acumulada >= PNAT.qtde_saldo
),

cobertura_sd2 AS (
  SELECT
    pn,
    `of` AS of_cobertura,
    emissao AS data_cobertura,
    qtde_acumulada
  FROM notas_sd2_rank
  WHERE rn = 1
),

-- pn ainda sem cobertura na SD2, com o acumulado que ja tinham (para continuar do mesmo ponto)
sd2_leftover AS (
  SELECT
    PNAT.pn,
    PNAT.qtde_saldo,
    COALESCE(MAX(NA.qtde_acumulada), 0) AS qtde_acumulada_leftover
  FROM pn_cobertura_atual PNAT
  LEFT JOIN notas_sd2_acumulado NA ON NA.pn = PNAT.pn
  WHERE PNAT.pn NOT IN (SELECT pn FROM cobertura_sd2)
  GROUP BY PNAT.pn, PNAT.qtde_saldo
),

-- Passo 4: OFs ainda nao usadas na SD2, com data projetada (previsao_faturamento -> fallback objeto_dezena_atual)
ofs_projetadas AS (
  SELECT
    ODF.pn,
    ODF.`of`,
    ODF.qtde,
    CAST(MAX(PFAT.`Emissão`) AS DATE) AS pfat_emissao,
    CAST(MAX(OBJD.de_simul) AS DATE) AS objd_de_simul
  FROM ordem_fabricacao ODF
  JOIN sd2_leftover SL ON SL.pn = ODF.pn
  LEFT JOIN pbi.vwf_previsao_faturamento PFAT ON PFAT.`Nro Doc` = ODF.`of`
  LEFT JOIN objeto_dezena_atual OBJD ON OBJD.`of` = ODF.`of`
  LEFT JOIN notas_sd2 NS ON NS.pn = ODF.pn AND NS.`of` = ODF.`of`
  WHERE NS.`of` IS NULL
  GROUP BY ODF.pn, ODF.`of`, ODF.qtde
),

-- nao faz sentido "cobrir no passado": ignora pfat_emissao/objd_de_simul
-- anteriores a hoje (previsao vencida que nunca virou nota real)
ofs_projetadas_calc AS (
  SELECT
    pn,
    `of`,
    qtde,
    COALESCE(
      CASE WHEN pfat_emissao >= CURDATE() THEN pfat_emissao END,
      CASE WHEN objd_de_simul >= CURDATE() THEN objd_de_simul END
    ) AS data_projecao,
    CASE
      WHEN pfat_emissao >= CURDATE() THEN 'PROJETADO'
      WHEN objd_de_simul >= CURDATE() THEN 'PLANEJADO'
      ELSE NULL
    END AS fonte_projecao
  FROM ofs_projetadas
),

ofs_projetadas_acumulado AS (
  SELECT
    pn,
    `of`,
    qtde,
    data_projecao,
    fonte_projecao,
    SUM(qtde) OVER (
      PARTITION BY pn
      ORDER BY (data_projecao IS NULL), data_projecao, `of`
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS qtde_acumulada_projetada
  FROM ofs_projetadas_calc
),

projetadas_rank AS (
  SELECT
    OA.pn,
    OA.`of` AS of_projecao,
    OA.data_projecao AS data_projetada,
    OA.fonte_projecao,
    OA.qtde_acumulada_projetada,
    SL.qtde_acumulada_leftover,
    ROW_NUMBER() OVER (
      PARTITION BY OA.pn
      ORDER BY (OA.data_projecao IS NULL), OA.data_projecao, OA.`of`
    ) AS rn
  FROM ofs_projetadas_acumulado OA
  JOIN sd2_leftover SL ON SL.pn = OA.pn
  WHERE OA.qtde_acumulada_projetada >= (SL.qtde_saldo - SL.qtde_acumulada_leftover)
),

cobertura_projetada AS (
  SELECT
    pn,
    of_projecao,
    data_projetada,
    (qtde_acumulada_projetada + qtde_acumulada_leftover) AS qtde_acumulada_final,
    COALESCE(fonte_projecao, 'ERRO') AS status_projecao
  FROM projetadas_rank
  WHERE rn = 1
),

resultado AS (
  SELECT
    PNAT.pn,
    PNAT.qtde_saldo,
    COALESCE(CS.of_cobertura, CP.of_projecao) AS `of`,
    COALESCE(CS.data_cobertura, CP.data_projetada) AS data_cobertura,
    COALESCE(CS.qtde_acumulada, CP.qtde_acumulada_final, SL.qtde_acumulada_leftover, 0) AS qtde_acumulada,
    CASE
      WHEN CS.pn IS NOT NULL THEN 'COBERTO'
      WHEN CP.pn IS NOT NULL THEN CP.status_projecao
      ELSE 'DESCOBERTO'
    END AS status
  FROM pn_cobertura_atual PNAT
  LEFT JOIN cobertura_sd2 CS ON CS.pn = PNAT.pn
  LEFT JOIN sd2_leftover SL ON SL.pn = PNAT.pn
  LEFT JOIN cobertura_projetada CP ON CP.pn = PNAT.pn
)

SELECT
  R.pn,
  R.qtde_saldo,
  R.`of`,
  R.data_cobertura,
  R.qtde_acumulada,
  R.status,
  OBJD.de_simul
FROM resultado R
LEFT JOIN objeto_dezena_atual OBJD ON OBJD.`of` = R.`of`
ORDER BY R.pn;
