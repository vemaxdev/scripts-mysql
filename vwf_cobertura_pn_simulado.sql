CREATE ALGORITHM=UNDEFINED DEFINER=`vemax`@`%` SQL SECURITY DEFINER VIEW `pbi`.`vwf_cobertura_pn_simulado` AS

WITH cfg_islands AS (
  -- agrupa execucoes consecutivas (por id) com o mesmo data_periodo_final,
  -- para diferenciar um periodo "de verdade" de um reprocessamento isolado
  SELECT data_periodo_final, MIN(id) AS min_id, MAX(id) AS max_id, COUNT(*) AS cnt
  FROM (
    SELECT id, data_periodo_final,
           ROW_NUMBER() OVER (ORDER BY id)
           - ROW_NUMBER() OVER (PARTITION BY data_periodo_final ORDER BY id) AS grp
    FROM controle_processamento_cobertura
  ) t
  GROUP BY data_periodo_final, grp
),

cfg_atual AS (
  SELECT data_periodo_inicial, data_periodo_final
  FROM controle_processamento_cobertura
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

-- status "oficial" do sistema, derivado de pn_situacao_cobertura.situacao
-- (prefixo antes do "_", ex: DESCOBERTO_MANUFATURA -> DESCOBERTO)
SIT_ATUAL AS (
  SELECT
    PSC.pn,
    SUBSTRING_INDEX(PSC.situacao, '_', 1) AS stts_atendimento
  FROM pn_situacao_cobertura PSC
),

-- notas reais na SD2 (via ordem_fabricacao, nao pn_extrato_cobertura)
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

-- primeira nota que cobre o saldo (se houver)
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
-- carrega tambem stts_atendimento (via SIT_ATUAL), pra decidir la na frente se projeta ou nao
sd2_leftover AS (
  SELECT
    PNAT.pn,
    PNAT.qtde_saldo,
    SIT.stts_atendimento,
    COALESCE(MAX(NA.qtde_acumulada), 0) AS qtde_acumulada_leftover
  FROM pn_cobertura_atual PNAT
  LEFT JOIN notas_sd2_acumulado NA ON NA.pn = PNAT.pn
  LEFT JOIN SIT_ATUAL SIT ON SIT.pn = PNAT.pn
  WHERE PNAT.pn NOT IN (SELECT pn FROM cobertura_sd2)
  GROUP BY PNAT.pn, PNAT.qtde_saldo, SIT.stts_atendimento
),

-- OFs ainda nao usadas na SD2, com data projetada vinda so de objeto_dezena_atual.de_simul
-- (ao contrario da vwf_cobertura_pn, aqui NAO usa previsao_faturamento)
-- so projeta pn que o sistema ainda considera DESCOBERTO (stts_atendimento)
-- so entram no calculo OFs que existem em objeto_dezena_atual; OFs fora dessa
-- tabela nao sao consideradas nem sequer como "sem data"
ofs_projetadas AS (
  SELECT
    ODF.pn,
    ODF.`of`,
    ODF.qtde,
    CAST(MAX(OBJD.de_simul) AS DATE) AS objd_de_simul
  FROM ordem_fabricacao ODF
  JOIN sd2_leftover SL ON SL.pn = ODF.pn AND SL.stts_atendimento = 'DESCOBERTO'
  LEFT JOIN objeto_dezena_atual OBJD ON OBJD.`of` = ODF.`of`
  LEFT JOIN notas_sd2 NS ON NS.pn = ODF.pn AND NS.`of` = ODF.`of`
  WHERE NS.`of` IS NULL
    AND OBJD.`of` IS NOT NULL
  GROUP BY ODF.pn, ODF.`of`, ODF.qtde
),

-- so descarta objd_de_simul fora do periodo combinado (anterior ao inicio do
-- periodo atual); atrasada mas ainda dentro do periodo continua valida
ofs_projetadas_calc AS (
  SELECT
    OP.pn,
    OP.`of`,
    OP.qtde,
    CASE WHEN OP.objd_de_simul >= CFG.data_periodo_inicial THEN OP.objd_de_simul END AS data_projecao
  FROM ofs_projetadas OP
  CROSS JOIN CFG
),

-- total pendente por pn (com + sem data), pra classificar quando as OFs com
-- data sozinhas nao bastam
ofs_pendentes_totais AS (
  SELECT
    pn,
    SUM(qtde) AS qtde_pendente_total,
    MAX(CASE WHEN data_projecao IS NOT NULL THEN 1 ELSE 0 END) AS tem_of_datada
  FROM ofs_projetadas_calc
  GROUP BY pn
),

-- acumulado cronologico so das OFs com data (pra achar a primeira que cobre o saldo)
ofs_projetadas_dated_acumulado AS (
  SELECT
    pn,
    `of`,
    qtde,
    data_projecao,
    SUM(qtde) OVER (
      PARTITION BY pn
      ORDER BY data_projecao, `of`
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS qtde_acumulada_projetada
  FROM ofs_projetadas_calc
  WHERE data_projecao IS NOT NULL
),

projetadas_rank AS (
  SELECT
    OA.pn,
    OA.`of` AS of_projecao,
    OA.data_projecao AS data_projetada,
    OA.qtde_acumulada_projetada,
    SL.qtde_acumulada_leftover,
    ROW_NUMBER() OVER (
      PARTITION BY OA.pn
      ORDER BY OA.data_projecao, OA.`of`
    ) AS rn
  FROM ofs_projetadas_dated_acumulado OA
  JOIN sd2_leftover SL ON SL.pn = OA.pn
  WHERE OA.qtde_acumulada_projetada >= (SL.qtde_saldo - SL.qtde_acumulada_leftover)
),

-- pn cobertos so com OFs com data, em ordem cronologica
cobertura_projetada_com_data AS (
  SELECT
    pn,
    of_projecao,
    data_projetada,
    (qtde_acumulada_projetada + qtde_acumulada_leftover) AS qtde_acumulada_final,
    'COB' AS status_projecao
  FROM projetadas_rank
  WHERE rn = 1
),

-- pn cuja OFs com data nao bastam sozinhas: classifica sem projetar data
-- - SEMOF: nenhuma OF pendente tem data, independente da soma bater o saldo
-- - COMOF: ha OF com data, e a soma de tudo (com + sem data) bate o saldo,
--   mas depende de OF sem data pra fechar
-- - STKSEMOF: ha OF com data, mas nem somando tudo bate o saldo
cobertura_projetada_sem_data AS (
  SELECT
    SL.pn,
    CAST(NULL AS CHAR) AS of_projecao,
    CAST(NULL AS DATE) AS data_projetada,
    (SL.qtde_acumulada_leftover + COALESCE(PT.qtde_pendente_total, 0)) AS qtde_acumulada_final,
    CASE
      WHEN COALESCE(PT.tem_of_datada, 0) = 0 THEN 'SEMOF'
      WHEN (SL.qtde_acumulada_leftover + COALESCE(PT.qtde_pendente_total, 0)) >= SL.qtde_saldo THEN 'COMOF'
      ELSE 'STKSEMOF'
    END AS status_projecao
  FROM sd2_leftover SL
  LEFT JOIN ofs_pendentes_totais PT ON PT.pn = SL.pn
  WHERE SL.stts_atendimento = 'DESCOBERTO'
    AND SL.pn NOT IN (SELECT pn FROM cobertura_projetada_com_data)
),

cobertura_projetada AS (
  SELECT pn, of_projecao, data_projetada, qtde_acumulada_final, status_projecao
  FROM cobertura_projetada_com_data
  UNION ALL
  SELECT pn, of_projecao, data_projetada, qtde_acumulada_final, status_projecao
  FROM cobertura_projetada_sem_data
),

-- combina stts_atendimento (sistema, via SIT_ATUAL) com a nossa analise (notas reais + projecao):
-- - se achou nota real (CS), status = COBERTO, com data
-- - senao, se o sistema ja diz COBERTO, mantem COBERTO mas sem data (nao projeta)
-- - senao, usa a projecao (CP), se houver
-- - senao, fica DESCOBERTO
resultado AS (
  SELECT
    PNAT.pn,
    PNAT.qtde_saldo,
    SIT.stts_atendimento,
    COALESCE(CS.of_cobertura, CP.of_projecao) AS `of`,
    COALESCE(CS.data_cobertura, CP.data_projetada) AS data_cobertura,
    COALESCE(CS.qtde_acumulada, CP.qtde_acumulada_final, SL.qtde_acumulada_leftover, 0) AS qtde_acumulada,
    CASE
      WHEN CS.pn IS NOT NULL THEN 'COBERTO'
      WHEN CP.pn IS NOT NULL THEN CP.status_projecao
      WHEN SIT.stts_atendimento = 'COBERTO' THEN 'COBERTO'
      ELSE 'DESCOBERTO'
    END AS status,
    LEFT(PNAT.prio, 6) as prio
  FROM pn_cobertura_atual PNAT
  LEFT JOIN cobertura_sd2 CS ON CS.pn = PNAT.pn
  LEFT JOIN sd2_leftover SL ON SL.pn = PNAT.pn
  LEFT JOIN cobertura_projetada CP ON CP.pn = PNAT.pn
  LEFT JOIN SIT_ATUAL SIT ON SIT.pn = PNAT.pn
)

SELECT
  R.pn,
  R.qtde_saldo,
  R.stts_atendimento,
  R.status AS status_analise,
  R.`of`,
  R.data_cobertura,
  R.qtde_acumulada,
  CASE
    WHEN (CASE WHEN R.status = 'COBERTO' THEN 'COBERTO' ELSE 'DESCOBERTO' END) = R.stts_atendimento
      THEN 'OK'
    ELSE 'DIVERGENTE'
  END AS comparativo,
  OBJD.de_simul,
  R.prio
FROM resultado R
LEFT JOIN objeto_dezena_atual OBJD ON OBJD.`of` = R.`of`
ORDER BY R.pn;
