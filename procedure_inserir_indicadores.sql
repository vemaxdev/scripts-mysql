DROP PROCEDURE IF EXISTS manufatura.sp_inserir_indicadores_poack;

DELIMITER $$

CREATE PROCEDURE manufatura.sp_inserir_indicadores_poack()
BEGIN
  DECLARE v_ordens_ra INT;
  DECLARE v_vencidos_ab INT;
  DECLARE v_vencidos_at INT;
  DECLARE v_entrega_maior_promessa_ab INT;
  DECLARE v_entrega_maior_promessa_at INT;
  DECLARE v_simulada_maior_entrega_ab INT;
  DECLARE v_simulada_maior_entrega_at INT;
  DECLARE v_ciclo_zerado INT;
  DECLARE v_oc_maior_180_dias INT;
  DECLARE v_kanban_sem_of INT;
  DECLARE v_priorizacoes DECIMAL(9,4);
  DECLARE v_oc_remessa_passado DECIMAL(9,4);
  DECLARE v_otd DECIMAL(9,4);
  DECLARE v_ciclo DECIMAL(9,4);
  DECLARE v_total_multas DECIMAL(15,2);

  SELECT
    COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%RA%' THEN IPA.ID END),
    COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AB%' AND IPA.dt_entrega < CURDATE() THEN IPA.ID END),
    COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AT%' AND IPA.dt_entrega < CURDATE() THEN IPA.ID END),
    COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AB%' AND IPA.dt_entrega > IPA.dt_promessa THEN IPA.ID END),
    COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AT%' AND IPA.dt_entrega > IPA.dt_promessa THEN IPA.ID END),
    COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AB%' AND ODA.de_simul > IPA.dt_entrega THEN IPA.ID END),
    COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AT%' AND ODA.de_simul > IPA.dt_entrega THEN IPA.ID END),
    COUNT(DISTINCT CASE WHEN IPA.ciclo = 0 THEN IPA.ID END),
    COUNT(DISTINCT CASE WHEN DATEDIFF(CURDATE(), POC.data_criacao) > 180 THEN IPA.ID END),
    COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.tipo_po IN ('ZNBA','ZNBC') AND ODF.`of` IS NULL THEN IPA.ID END),
    COUNT(DISTINCT CASE WHEN IPA.prio IS NOT NULL THEN IPA.ID END) / COUNT(DISTINCT IPA.ID),
    COUNT(DISTINCT CASE WHEN IPA.dt_remessa < DATE_ADD(DATE_SUB(CURDATE(), INTERVAL IPA.`1a_nf` DAY), INTERVAL IPA.ciclo DAY) THEN IPA.ID END) / COUNT(DISTINCT IPA.ID),
    COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND (IPA.status LIKE '%AB%' OR IPA.status LIKE '%AT%') AND IPA.dt_entrega >= CURDATE() THEN IPA.ID END)
      / COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND (IPA.status LIKE '%AB%' OR IPA.status LIKE '%AT%') THEN IPA.ID END),
    COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AB%' AND DATE_ADD(DATE_SUB(CURDATE(), INTERVAL IPA.`1a_nf` DAY), INTERVAL IPA.ciclo DAY) >= CURDATE() THEN IPA.ID END)
      / COUNT(DISTINCT CASE WHEN IPA.action = 'LIDO' AND IPA.status LIKE '%AB%' THEN IPA.ID END)
  INTO
    v_ordens_ra,
    v_vencidos_ab,
    v_vencidos_at,
    v_entrega_maior_promessa_ab,
    v_entrega_maior_promessa_at,
    v_simulada_maior_entrega_ab,
    v_simulada_maior_entrega_at,
    v_ciclo_zerado,
    v_oc_maior_180_dias,
    v_kanban_sem_of,
    v_priorizacoes,
    v_oc_remessa_passado,
    v_otd,
    v_ciclo
  FROM manufatura.item_poack_atual IPA
  LEFT JOIN manufatura.ordem_fabricacao ODF ON ODF.`oc_linha` = CONCAT(IPA.`po`, '/', LPAD(IPA.linha, 5, 0))
  LEFT JOIN manufatura.objeto_dezena_atual ODA ON ODA.`of` = ODF.`of`
  LEFT JOIN (
    SELECT `po`, MIN(`data_criacao`) AS `data_criacao`
    FROM manufatura.poack_cabecalho
    GROUP BY `po`
  ) POC ON POC.`po` = IPA.`po`;

  SELECT SUM(V.`Multa total`)
  INTO v_total_multas
  FROM manufatura.vw_atraso_emissao_edi_remessa V
  WHERE YEAR(V.emissao_sd2) = YEAR(CURDATE())
    AND MONTH(V.emissao_sd2) = MONTH(CURDATE());

  INSERT INTO pbi.indicadores_poack (
    dt_registro,
    ordens_ra,
    vencidos_ab,
    vencidos_at,
    entrega_maior_promessa_ab,
    entrega_maior_promessa_at,
    simulada_maior_entrega_ab,
    simulada_maior_entrega_at,
    ciclo_zerado,
    oc_maior_180_dias,
    kanban_sem_of,
    priorizacoes,
    oc_remessa_passado,
    OTD,
    ciclo,
    total_multas
  )
  VALUES (
    CURDATE(),
    v_ordens_ra,
    v_vencidos_ab,
    v_vencidos_at,
    v_entrega_maior_promessa_ab,
    v_entrega_maior_promessa_at,
    v_simulada_maior_entrega_ab,
    v_simulada_maior_entrega_at,
    v_ciclo_zerado,
    v_oc_maior_180_dias,
    v_kanban_sem_of,
    v_priorizacoes,
    v_oc_remessa_passado,
    v_otd,
    v_ciclo,
    v_total_multas
  )
  AS novo
  ON DUPLICATE KEY UPDATE
    dt_registro = novo.dt_registro,
    ordens_ra = novo.ordens_ra,
    vencidos_ab = novo.vencidos_ab,
    vencidos_at = novo.vencidos_at,
    entrega_maior_promessa_ab = novo.entrega_maior_promessa_ab,
    entrega_maior_promessa_at = novo.entrega_maior_promessa_at,
    simulada_maior_entrega_ab = novo.simulada_maior_entrega_ab,
    simulada_maior_entrega_at = novo.simulada_maior_entrega_at,
    ciclo_zerado = novo.ciclo_zerado,
    oc_maior_180_dias = novo.oc_maior_180_dias,
    kanban_sem_of = novo.kanban_sem_of,
    priorizacoes = novo.priorizacoes,
    oc_remessa_passado = novo.oc_remessa_passado,
    OTD = novo.OTD,
    ciclo = novo.ciclo,
    total_multas = novo.total_multas;
END$$

DELIMITER ;
