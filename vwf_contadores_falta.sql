-- vwf_contadores_falta
-- Para cada PN em falta (extrato de faltas Embraer mais recente, pem = 'E'),
-- cruza com as ordens de fabricacao (OF) desse PN cujo item ja foi lido no PO/ACK,
-- e classifica a situacao de cobertura da falta em um unico tipo mutuamente exclusivo.
--
-- Colunas de saida (subquery c):
--   pn                    : part number em falta
--   qtd_falta             : quantidade total em falta para o pn (soma do extrato)
--   possui_objeto_dezena  : 1 se ao menos uma OF do pn tem registro em objeto_dezena_atual
--   possui_of_eft         : 1 se ao menos uma OF do pn tem objeto_dezena com
--                           acionamento_direto contendo 'EFT' (MAX agrega por pn)
--   qtde_of               : soma da quantidade de todas as OFs do pn
--   qtde_of_eft           : soma da quantidade apenas das OFs que tem objeto_dezena
--                           com acionamento_direto contendo 'EFT'
--   cobre_falta           : 1 se qtde_of (total) >= qtd_falta
--
-- Colunas de saida (SELECT externo):
--   acionamento_efetivo   : 1 se qtde_of_eft (quantidade com plano EFT) >= qtd_falta,
--                           ou seja, se o acionamento efetivo por si so ja cobre a falta
--
-- tipo_falta (CASE, avaliado em ordem, resultado NULL = sem problema):
--   semof_semplano       : possui_of_eft = 0 e qtde_of  < qtd_falta (nenhuma OF com EFT)
--   comof_semplano        : possui_of_eft = 0 e qtde_of >= qtd_falta (nenhuma OF com EFT)
--   insuficiente_semof    : possui_of_eft = 1 e acionamento_efetivo = 0 e qtde_of  < qtd_falta
--   insuficiente_comof    : possui_of_eft = 1 e acionamento_efetivo = 0 e qtde_of >= qtd_falta
--   (NULL)                : demais casos, cobertura ok
-- A ordem do CASE garante exclusividade: quando possui_of_eft = 0 uma das duas
-- primeiras condicoes sempre casa antes de chegar nas de "insuficiente" (que so
-- sao alcancadas quando ja existe ao menos uma OF com EFT, mas em quantidade
-- insuficiente para cobrir a falta).
CREATE ALGORITHM=UNDEFINED DEFINER=`vemax`@`%` SQL SECURITY DEFINER VIEW `pbi`.`vwf_contadores_falta` AS

SELECT c.*,
    IF(c.qtde_of_eft >= c.qtd_falta, 1, 0) AS acionamento_efetivo,
    CASE
        WHEN c.possui_of_eft = 0 AND c.qtde_of < c.qtd_falta THEN 'semof_semplano'
        WHEN c.possui_of_eft = 0 AND c.qtde_of >= c.qtd_falta THEN 'comof_semplano'
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
        -- pn tem ao menos uma OF com acionamento_direto com EFT (MAX = basta uma)
        MAX(IF(EXISTS (
            SELECT 1
            FROM manufatura.objeto_dezena_atual oda
            WHERE oda.`of` = odf.`of`
            AND oda.acionamento_direto LIKE '%EFT%'
        ), 1, 0)) AS possui_of_eft,
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
