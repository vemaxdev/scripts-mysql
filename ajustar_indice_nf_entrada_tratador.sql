-- Adiciona indice em oc_linha para acelerar a view pbi.vwf_aderencia
-- (a subquery EXISTS fazia table scan completo da tabela por falta de indice)
CREATE INDEX idx_nf_entrada_tratador_oc_linha
  ON manufatura.nf_entrada_tratador (oc_linha);
