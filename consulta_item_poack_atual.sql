SELECT
  COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%RA%' THEN IPA.ID END) AS ordens_ra,
  COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AB%' AND IPA.dt_entrega < CURDATE() THEN IPA.ID END) AS vencidos_ab,
  COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AT%' AND IPA.dt_entrega < CURDATE() THEN IPA.ID END) AS vencidos_at,
  COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AB%' AND IPA.dt_entrega > IPA.dt_promessa THEN IPA.ID END) AS entrega_maior_promessa_ab,
  COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AT%' AND IPA.dt_entrega > IPA.dt_promessa THEN IPA.ID END) AS entrega_maior_promessa_at,
  COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AB%' AND ODA.de_simul > IPA.dt_entrega THEN IPA.ID END) AS simulada_maior_entrega_ab,
  COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AT%' AND ODA.de_simul > IPA.dt_entrega THEN IPA.ID END) AS simulada_maior_entrega_at,
  COUNT(DISTINCT CASE WHEN IPA.ciclo = 0 THEN IPA.ID END) AS ciclo_zerado,
  COUNT(DISTINCT CASE WHEN DATEDIFF(CURDATE(), POC.data_criacao) > 180 THEN IPA.ID END) AS oc_maior_180_dias,
  COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.tipo_po IN ('ZNBA','ZNBC') AND ODF.`of` IS NULL THEN IPA.ID END) AS kanban_sem_of,
  COUNT(DISTINCT CASE WHEN IPA.prio IS NOT NULL THEN IPA.ID END) / COUNT(DISTINCT IPA.ID) AS priorizacoes,
  COUNT(DISTINCT CASE WHEN IPA.dt_remessa < DATE_ADD(DATE_SUB(CURDATE(), INTERVAL IPA.`1a_nf` DAY), INTERVAL IPA.ciclo DAY) THEN IPA.ID END) / COUNT(DISTINCT IPA.ID) AS oc_remessa_passado,
  COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AB%' AND IPA.dt_entrega >= CURDATE() THEN IPA.ID END) / COUNT(DISTINCT IPA.ID) AS OTD,
  COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AB%' AND DATE_ADD(DATE_SUB(CURDATE(), INTERVAL IPA.`1a_nf` DAY), INTERVAL IPA.ciclo DAY) >= CURDATE() THEN IPA.ID END)
    / COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AB%' THEN IPA.ID END) AS ciclo
FROM manufatura.item_poack_atual IPA

LEFT JOIN manufatura.ordem_fabricacao ODF ON ODF.`oc_linha` = CONCAT(IPA.`po`, '/', LPAD(IPA.linha, 5, 0))

LEFT JOIN manufatura.objeto_dezena_atual ODA ON ODA.`of` = ODF.`of`

LEFT JOIN (
  SELECT `po`, MIN(`data_criacao`) AS `data_criacao`
  FROM manufatura.poack_cabecalho
  GROUP BY `po`
) POC ON POC.`po` = IPA.`po`
