CREATE OR REPLACE ALGORITHM=UNDEFINED DEFINER=`vemax`@`%` SQL SECURITY DEFINER VIEW `pbi`.`vwf_cob_dinamica_pn` AS

SELECT
  E.pn,
  M0.qtd AS qtde_m0,
  M0.status AS status_m0,
  M1.qtd AS qtde_m1,
  M1.status AS status_m1,
  M2.qtd AS qtde_m2,
  M2.status AS status_m2,
  CP.data_cobertura AS planejado
FROM manufatura.vw_cobertura_estoque_dinamica_atual E
LEFT JOIN manufatura.vw_cobertura_estoque_dinamica_mes_atual M0
  ON M0.item_id = E.id
 AND M0.mes_ref = DATE_FORMAT(CURDATE(), '%Y-%m-01')
LEFT JOIN manufatura.vw_cobertura_estoque_dinamica_mes_atual M1
  ON M1.item_id = E.id
 AND M1.mes_ref = DATE_FORMAT(CURDATE() + INTERVAL 1 MONTH, '%Y-%m-01')
LEFT JOIN manufatura.vw_cobertura_estoque_dinamica_mes_atual M2
  ON M2.item_id = E.id
 AND M2.mes_ref = DATE_FORMAT(CURDATE() + INTERVAL 2 MONTH, '%Y-%m-01')
LEFT JOIN pbi.vwf_cobertura_pn CP ON CP.pn = E.pn
-- apenas PN que tenham item no poack com action LIDO ou NFE
WHERE EXISTS (
  SELECT 1
  FROM manufatura.item_poack_atual IPA
  WHERE IPA.part_number = E.pn
    AND IPA.action IN ('LIDO', 'NFE')
)
ORDER BY E.pn;
