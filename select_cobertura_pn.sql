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

-- linha de pn_extrato_cobertura que fecha a conta de cada pn: MAX(id) e a
-- ultima OF da caminhada que o processo de extrato ja fez ate o saldo bater
-- (ou a ultima tentativa conhecida, quando nem somando tudo cobre)
extrato_atual AS (
  SELECT PEC.pn, PEC.ordem_fabricacao AS `of`, PEC.categoria, PEC.saldo_final_pn
  FROM manufatura.pn_extrato_cobertura PEC
  JOIN (
    SELECT pn, MAX(id) AS max_id
    FROM manufatura.pn_extrato_cobertura
    GROUP BY pn
  ) M ON M.pn = PEC.pn AND M.max_id = PEC.id
),

-- categoria ROMANEIO/NF = cobertura real; cruza essa OF com a SD2 pra achar a
-- data real da nota (oc_linha vem de ordem_fabricacao pelo `of`; mesmo filtro
-- de sempre: numpedcomp/itempedcom batendo com oc_linha, cliente Embraer
-- IN (6,7,8), dentro do periodo CFG)
cobertura_sd2 AS (
  SELECT
    EA.pn,
    EA.`of` AS of_cobertura,
    MAX(SD2.emissao) AS data_cobertura
  FROM extrato_atual EA
  JOIN ordem_fabricacao ODF ON ODF.`of` = EA.`of`
  JOIN CFG ON 1 = 1
  JOIN totvs_sd2 SD2
    ON SD2.`of` = EA.`of`
   AND SD2.numpedcomp = SUBSTRING_INDEX(ODF.oc_linha, '/', 1)
   AND SD2.itempedcom <> ''
   AND CAST(SD2.itempedcom AS UNSIGNED) = CAST(SUBSTRING_INDEX(ODF.oc_linha, '/', -1) AS UNSIGNED)
   AND SD2.cliente IN (6, 7, 8)
   AND SD2.emissao BETWEEN CFG.data_periodo_inicial_ajustado AND LAST_DAY(CFG.data_periodo_inicial)
  WHERE EA.categoria IN ('ROMANEIO', 'NF')
  GROUP BY EA.pn, EA.`of`
),

-- categoria fora de ROMANEIO/NF = ainda pendente; projeta a data so com a OF
-- do extrato (join objeto_dezena_atual.de_simul), sem somar outras OFs do pn.
-- nao faz sentido "cobrir no passado": ignora de_simul anterior a hoje
-- status_projecao passa a ser a propria categoria do extrato (DESCOBERTO_MANUFATURA/DESCOBERTO/etc)
cobertura_projetada AS (
  SELECT
    EA.pn,
    EA.`of` AS of_projecao,
    CASE WHEN OBJD.de_simul >= CURDATE() THEN CAST(OBJD.de_simul AS DATE) END AS data_projetada,
    EA.categoria AS status_projecao
  FROM extrato_atual EA
  LEFT JOIN objeto_dezena_atual OBJD ON OBJD.`of` = EA.`of`
  WHERE EA.categoria NOT IN ('ROMANEIO', 'NF')
),

resultado AS (
  SELECT
    PNAT.pn,
    PNAT.qtde_saldo,
    COALESCE(CS.of_cobertura, CP.of_projecao) AS `of`,
    COALESCE(CS.data_cobertura, CP.data_projetada) AS data_cobertura,
    GREATEST(PNAT.qtde_saldo - COALESCE(EA.saldo_final_pn, PNAT.qtde_saldo), 0) AS qtde_acumulada,
    CASE
      WHEN CS.pn IS NOT NULL THEN 'COBERTO'
      WHEN CP.pn IS NOT NULL THEN CP.status_projecao
      ELSE 'DESCOBERTO'
    END AS status
  FROM pn_cobertura_atual PNAT
  LEFT JOIN extrato_atual EA ON EA.pn = PNAT.pn
  LEFT JOIN cobertura_sd2 CS ON CS.pn = PNAT.pn
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
