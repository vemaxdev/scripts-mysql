-- 1. Remove duplicatas existentes, mantendo a linha mais recente (maior ID) de cada dia
DELETE T1
FROM pbi.indicadores_poack T1
INNER JOIN pbi.indicadores_poack T2
  ON T1.dt_registro = T2.dt_registro
 AND T1.ID < T2.ID;

-- 2. Remove o indice antigo (nao-unico), se existir, para nao ficar redundante
ALTER TABLE pbi.indicadores_poack
  DROP INDEX idx_indicadores_poack_dt_registro;

-- 3. Adiciona a chave unica: garante no maximo 1 linha por dia dali em diante
ALTER TABLE pbi.indicadores_poack
  ADD UNIQUE KEY uq_indicadores_poack_dt_registro (dt_registro);

-- 4. Adiciona a coluna do indicador kanban_sem_of
ALTER TABLE pbi.indicadores_poack
  ADD COLUMN kanban_sem_of int DEFAULT NULL AFTER oc_maior_180_dias;

-- 5. Remove duplicatas por mes, mantendo a linha mais recente (maior ID) de cada mes
DELETE T1
FROM pbi.indicadores_poack T1
INNER JOIN pbi.indicadores_poack T2
  ON DATE_FORMAT(T1.dt_registro, '%Y-%m') = DATE_FORMAT(T2.dt_registro, '%Y-%m')
 AND T1.ID < T2.ID;

-- 6. Remove a chave unica antiga (por dia)
ALTER TABLE pbi.indicadores_poack
  DROP INDEX uq_indicadores_poack_dt_registro;

-- 7. Adiciona coluna gerada com o mes de referencia (AAAA-MM)
ALTER TABLE pbi.indicadores_poack
  ADD COLUMN ref_mes CHAR(7) GENERATED ALWAYS AS (DATE_FORMAT(dt_registro, '%Y-%m')) STORED AFTER dt_registro;

-- 8. Adiciona a chave unica por mes: garante no maximo 1 linha por mes dali em diante
ALTER TABLE pbi.indicadores_poack
  ADD UNIQUE KEY uq_indicadores_poack_ref_mes (ref_mes);
