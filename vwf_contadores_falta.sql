-- vwf_contadores_falta
-- Para cada PN em falta (extrato de faltas Embraer mais recente, pem = 'E'),
-- cruza com as ordens de fabricacao (OF) desse PN cujo item ja foi lido no PO/ACK,
-- e classifica a situacao de cobertura da falta em um unico tipo mutuamente exclusivo.
--
-- Colunas de saida (subquery c):
--   pn                    : part number em falta
--   qtd_falta             : quantidade total em falta para o pn (soma do extrato)
--   possui_objeto_dezena  : 1 se ao menos uma OF do pn tem registro em objeto_dezena_atual
--   acionamento_efetivo   : 1 somente se TODAS as OFs do pn tem objeto_dezena com
--                           acionamento_direto contendo 'EFT' (MIN agrega por pn)
--   qtde_of               : soma da quantidade de todas as OFs do pn
--   qtde_of_eft           : soma da quantidade apenas das OFs que tem objeto_dezena
--                           com acionamento_direto contendo 'EFT'
--   cobre_falta           : 1 se qtde_of (total) >= qtd_falta
--
-- tipo_falta (CASE, avaliado em ordem, resultado NULL = sem problema):
--   semof_semplano      : acionamento_efetivo = 0 e qtde_of  < qtd_falta
--   comof_semplano       : acionamento_efetivo = 0 e qtde_of >= qtd_falta
--   insuficiente_semof   : acionamento_efetivo = 1 e qtde_of_eft < qtd_falta e qtde_of  < qtd_falta
--   insuficiente_comof   : acionamento_efetivo = 1 e qtde_of_eft < qtd_falta e qtde_of >= qtd_falta
--   (NULL)               : demais casos, cobertura ok
-- A ordem do CASE garante exclusividade: quando acionamento_efetivo = 0 uma das
-- duas primeiras condicoes sempre casa antes de chegar nas de "insuficiente".
CREATE ALGORITHM=UNDEFINED DEFINER=`vemax`@`%` SQL SECURITY DEFINER VIEW `pbi`.`vwf_contadores_falta` AS

SELECT c.*,
    CASE
        WHEN c.acionamento_efetivo = 0 AND c.qtde_of < c.qtd_falta THEN 'semof_semplano'
        WHEN c.acionamento_efetivo = 0 AND c.qtde_of >= c.qtd_falta THEN 'comof_semplano'
        WHEN c.qtde_of_eft < c.qtd_falta AND c.qtde_of < c.qtd_falta THEN 'insuficiente_semof'
        WHEN c.qtde_of_eft < c.qtd_falta AND c.qtde_of >= c.qtd_falta THEN 'insuficiente_comof'
    END AS tipo_falta
FROM (
    SELECT efe.pn, efe.qtd_falta,
        -- pn tem alguma OF com registro atual em objeto_dezena_atual
        MAX(IF(EXISTS (
            SELECT 1
            FROM manufatura.objeto_dezena_atual oda
            WHERE oda.`of` = odf.`of`
        ), 1, 0)) AS possui_objeto_dezena,
        -- todas as OFs do pn tem acionamento_direto com EFT (MIN = precisa valer para todas)
        MIN(IF(EXISTS (
            SELECT 1
            FROM manufatura.objeto_dezena_atual oda
            WHERE oda.`of` = odf.`of`
            AND oda.acionamento_direto LIKE '%EFT%'
        ), 1, 0)) AS acionamento_efetivo,
        -- quantidade total das OFs do pn
        sum(odf.qtde) AS qtde_of,
        -- quantidade das OFs do pn, somando so as OFs com acionamento EFT
        SUM(IF(EXISTS (
            SELECT 1
            FROM manufatura.objeto_dezena_atual oda
            WHERE oda.`of` = odf.`of`
            AND oda.acionamento_direto LIKE '%EFT%'
        ), odf.qtde, 0)) AS qtde_of_eft,
        IF(sum(odf.qtde) >= efe.qtd_falta, 1, 0) AS cobre_falta
    FROM (
        -- total em falta por pn, na data do extrato mais recente
        SELECT pn, SUM(qtd) AS qtd_falta
        FROM manufatura.extrato_faltas_embraer
        WHERE data_extrato = (
            SELECT MAX(data_extrato)
            FROM manufatura.extrato_faltas_embraer
        )
        AND pem = 'E'
        GROUP BY pn
    ) efe
    INNER JOIN manufatura.ordem_fabricacao odf ON odf.pn = efe.pn
    -- considera apenas OFs cujo item ja foi lido no PO/ACK
    WHERE EXISTS (
        SELECT 1
        FROM manufatura.item_poack_atual ipa
        WHERE CONCAT(ipa.po, '/', LPAD(ipa.linha, 5, '0')) = odf.oc_linha
        AND ipa.action = 'LIDO'
    )
    GROUP BY efe.pn, efe.qtd_falta
) c
