-- ordens_ra
SELECT COUNT(*) AS ordens_ra
FROM manufatura.item_poack_atual IPA
WHERE IPA.action = 'LIDO'
  AND IPA.status LIKE '%RA%';

-- vencidos_ab
SELECT COUNT(*) AS vencidos_ab
FROM manufatura.item_poack_atual IPA
WHERE IPA.action = 'LIDO'
  AND IPA.status LIKE '%AB%'
  AND IPA.dt_entrega < CURDATE();

-- vencidos_at
SELECT COUNT(*) AS vencidos_at
FROM manufatura.item_poack_atual IPA
WHERE IPA.action = 'LIDO'
  AND IPA.status LIKE '%AT%'
  AND IPA.dt_entrega < CURDATE();

-- entrega_maior_promessa_ab
SELECT COUNT(*) AS entrega_maior_promessa_ab
FROM manufatura.item_poack_atual IPA
WHERE IPA.action = 'LIDO'
  AND IPA.status LIKE '%AB%'
  AND IPA.dt_entrega > IPA.dt_promessa;

-- entrega_maior_promessa_at
SELECT COUNT(*) AS entrega_maior_promessa_at
FROM manufatura.item_poack_atual IPA
WHERE IPA.action = 'LIDO'
  AND IPA.status LIKE '%AT%'
  AND IPA.dt_entrega > IPA.dt_promessa;

-- simulada_maior_entrega_ab
SELECT COUNT(DISTINCT IPA.ID) AS simulada_maior_entrega_ab
FROM manufatura.item_poack_atual IPA
INNER JOIN manufatura.ordem_fabricacao ODF ON ODF.`oc_linha` = CONCAT(IPA.`po`, '/', LPAD(IPA.linha, 5, 0))
INNER JOIN manufatura.objeto_dezena_atual ODA ON ODA.`of` = ODF.`of`
WHERE IPA.action = 'LIDO'
  AND IPA.status LIKE '%AB%'
  AND ODA.de_simul > IPA.dt_entrega;

-- simulada_maior_entrega_at
SELECT COUNT(DISTINCT IPA.ID) AS simulada_maior_entrega_at
FROM manufatura.item_poack_atual IPA
INNER JOIN manufatura.ordem_fabricacao ODF ON ODF.`oc_linha` = CONCAT(IPA.`po`, '/', LPAD(IPA.linha, 5, 0))
INNER JOIN manufatura.objeto_dezena_atual ODA ON ODA.`of` = ODF.`of`
WHERE IPA.action = 'LIDO'
  AND IPA.status LIKE '%AT%'
  AND ODA.de_simul > IPA.dt_entrega;

-- ciclo_zerado
SELECT COUNT(*) AS ciclo_zerado
FROM manufatura.item_poack_atual IPA
WHERE IPA.ciclo = 0;

-- oc_maior_180_dias
SELECT COUNT(DISTINCT IPA.ID) AS oc_maior_180_dias
FROM manufatura.item_poack_atual IPA
INNER JOIN (
  SELECT `po`, MIN(`data_criacao`) AS `data_criacao`
  FROM manufatura.poack_cabecalho
  GROUP BY `po`
) POC ON POC.`po` = IPA.`po`
WHERE DATEDIFF(CURDATE(), POC.data_criacao) > 180;

-- priorizacoes
SELECT
  COUNT(CASE WHEN IPA.prio IS NOT NULL THEN 1 END) AS qtde_com_prio,
  COUNT(*) AS total_linhas,
  COUNT(CASE WHEN IPA.prio IS NOT NULL THEN 1 END) / COUNT(*) AS priorizacoes
FROM manufatura.item_poack_atual IPA;

-- oc_remessa_passado
SELECT
  IPA.ID,
  IPA.dt_remessa,
  IPA.`1a_nf`,
  IPA.ciclo,
  DATE_ADD(DATE_SUB(CURDATE(), INTERVAL IPA.`1a_nf` DAY), INTERVAL IPA.ciclo DAY) AS dt_ciclo,
  CASE WHEN IPA.dt_remessa < DATE_ADD(DATE_SUB(CURDATE(), INTERVAL IPA.`1a_nf` DAY), INTERVAL IPA.ciclo DAY) THEN 1 ELSE 0 END AS remessa_passado
FROM manufatura.item_poack_atual IPA;

SELECT
  COUNT(CASE WHEN IPA.dt_remessa < DATE_ADD(DATE_SUB(CURDATE(), INTERVAL IPA.`1a_nf` DAY), INTERVAL IPA.ciclo DAY) THEN 1 END) AS qtde_remessa_passado,
  COUNT(*) AS total_linhas,
  COUNT(CASE WHEN IPA.dt_remessa < DATE_ADD(DATE_SUB(CURDATE(), INTERVAL IPA.`1a_nf` DAY), INTERVAL IPA.ciclo DAY) THEN 1 END) / COUNT(*) AS oc_remessa_passado
FROM manufatura.item_poack_atual IPA;

-- ciclo
SELECT
  COUNT(CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AB%'
             AND DATE_ADD(DATE_SUB(CURDATE(), INTERVAL IPA.`1a_nf` DAY), INTERVAL IPA.ciclo DAY) >= CURDATE()
        THEN 1 END) AS qtde_ciclo_ok,
  COUNT(CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AB%' THEN 1 END) AS total_lido_ab,
  COUNT(CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AB%'
             AND DATE_ADD(DATE_SUB(CURDATE(), INTERVAL IPA.`1a_nf` DAY), INTERVAL IPA.ciclo DAY) >= CURDATE()
        THEN 1 END)
    / COUNT(CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AB%' THEN 1 END) AS ciclo
FROM manufatura.item_poack_atual IPA;

-- OTD
SELECT
  COUNT(CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AB%' AND IPA.dt_entrega >= CURDATE() THEN 1 END) AS qtde_otd,
  COUNT(*) AS total_linhas,
  COUNT(CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AB%' AND IPA.dt_entrega >= CURDATE() THEN 1 END) / COUNT(*) AS OTD
FROM manufatura.item_poack_atual IPA;

-- multas (mes atual)
SELECT SUM(V.`Multa total`) AS total_multas
FROM manufatura.vw_atraso_emissao_edi_remessa V
WHERE YEAR(V.emissao_sd2) = YEAR(CURDATE())
  AND MONTH(V.emissao_sd2) = MONTH(CURDATE());

-- kanban_sem_of
SELECT COUNT(DISTINCT IPA.ID) AS kanban_sem_of
FROM manufatura.item_poack_atual IPA
LEFT JOIN manufatura.ordem_fabricacao ODF ON ODF.`oc_linha` = CONCAT(IPA.`po`, '/', LPAD(IPA.linha, 5, 0))
WHERE IPA.action = 'LIDO'
  AND IPA.tipo_po IN ('ZNBA','ZNBC')
  AND ODF.`of` IS NULL;
