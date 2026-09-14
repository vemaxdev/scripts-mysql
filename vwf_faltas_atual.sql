-- vwf_faltas_atual
-- Faltas Embraer do extrato mais recente (manufatura.extrato_faltas_embraer
-- filtrado pela maior data_extrato), uma linha por linha do extrato, cruzadas
-- com as OFs do pn cujo item ja foi lido no PO/ACK (item_poack_atual LIDO).
--
-- Colunas calculadas:
--   qtd_acumulada         : soma da qtd das linhas do pn ate esta linha, com as linhas
--                           pem = 'E' primeiro, depois por necessidade (mais antiga
--                           primeiro), ns, id
--   possui_objeto_dezena  : 1 se ao menos uma OF do pn tem registro em objeto_dezena_atual
--   possui_of_eft         : 1 se ao menos uma OF do pn tem acionamento_direto contendo 'EFT'
--   qtde_of               : soma da quantidade das OFs do pn
--   qtde_of_eft           : soma da quantidade das OFs do pn com acionamento EFT
--   of / centrotrabalho   : OF que atende a linha e seu centro de trabalho atual
--                           (manufatura.vw_ultima_data_fluxo). As OFs do pn sao
--                           distribuidas pelas linhas na ordem da qtd_acumulada,
--                           da OF mais avancada no processo (maior
--                           centro_trabalho.sequencia_producao) para a menos avancada.
--                           A linha fica com a OF que atende sua primeira peca;
--                           NULL quando as OFs nao chegam ate a linha.
--   cobre_falta           : 1 se qtde_of >= qtd_acumulada
--   acionamento_efetivo   : 1 se qtde_of_eft >= qtd_acumulada
--   tipo_falta            : semof_semplano / comof_semplano / insuficiente_semof /
--                           insuficiente_comof (NULL = cobertura ok)
--   data_ciclo            : data prevista de fim do ciclo da OC/linha, pela ultima
--                           atualizacao do manufatura.monitor_oc_embraer
--   ciclo_status          : 'SEM OF' (sem data_ciclo), 'VENCIDO' (data_ciclo < hoje) ou 'OK'
--   sequencia_producao    : sequencia do centro de trabalho da OF
--   fase_manufatura       : 'PRE' se sequencia_producao < parametro DISPERSAO_CT_SEQ_CORTE
--                           (config.parametro, padrao 120), senao 'POS' (inclui sem OF)
-- PN sem nenhuma OF lida fica com contadores 0 (semof_semplano).
CREATE ALGORITHM=UNDEFINED DEFINER=`vemax`@`%` SQL SECURITY DEFINER VIEW `pbi`.`vwf_faltas_atual` AS

WITH
-- linhas do extrato mais recente, com a faixa de pecas acumuladas de cada linha
efe AS (
    SELECT
        e.*,
        SUM(e.qtd) OVER (
            PARTITION BY e.pn
            ORDER BY e.pem <> 'E', e.necessidade IS NULL, e.necessidade, e.ns, e.id
            ROWS UNBOUNDED PRECEDING
        ) AS qtd_acumulada
    FROM manufatura.extrato_faltas_embraer e
    WHERE e.data_extrato = (
        SELECT MAX(data_extrato)
        FROM manufatura.extrato_faltas_embraer
    )
),
-- OFs lidas no PO/ACK, com flags de objeto dezena e o centro de trabalho atual
odf AS (
    SELECT
        o.pn,
        o.`of`,
        o.qtde,
        -- OF tem registro atual em objeto_dezena_atual
        IF(EXISTS (
            SELECT 1
            FROM manufatura.objeto_dezena_atual oda
            WHERE oda.`of` = o.`of`
        ), 1, 0) AS tem_objeto_dezena,
        -- OF tem acionamento_direto com EFT
        IF(EXISTS (
            SELECT 1
            FROM manufatura.objeto_dezena_atual oda
            WHERE oda.`of` = o.`of`
            AND oda.acionamento_direto LIKE '%EFT%'
        ), 1, 0) AS tem_eft,
        u.centrotrabalho,
        ct.sequencia_producao
    FROM manufatura.ordem_fabricacao o
    -- fluxo mais recente da OF (a view pode repetir OF)
    LEFT JOIN (
        SELECT
            ordemfabricacao,
            centrotrabalho,
            ROW_NUMBER() OVER (PARTITION BY ordemfabricacao ORDER BY datafluxo DESC) AS rn
        FROM manufatura.vw_ultima_data_fluxo
    ) u
        ON u.ordemfabricacao = o.`of`
        AND u.rn = 1
    LEFT JOIN manufatura.centro_trabalho ct
        ON ct.ct = u.centrotrabalho
    -- considera apenas OFs cujo item ja foi lido no PO/ACK
    WHERE EXISTS (
        SELECT 1
        FROM manufatura.item_poack_atual ipa
        WHERE CONCAT(ipa.po, '/', LPAD(ipa.linha, 5, '0')) = o.oc_linha
        AND ipa.action = 'LIDO'
    )
    AND o.pn IN (SELECT pn FROM efe)
),
-- contadores das OFs por pn
ofp AS (
    SELECT
        pn,
        MAX(tem_objeto_dezena) AS possui_objeto_dezena,
        MAX(tem_eft) AS possui_of_eft,
        SUM(qtde) AS qtde_of,
        SUM(IF(tem_eft = 1, qtde, 0)) AS qtde_of_eft
    FROM odf
    GROUP BY pn
),
-- faixa de pecas acumuladas de cada OF, da mais avancada para a menos avancada
ofa AS (
    SELECT
        pn,
        `of`,
        centrotrabalho,
        sequencia_producao,
        qtde,
        SUM(qtde) OVER (
            PARTITION BY pn
            ORDER BY sequencia_producao IS NULL, sequencia_producao DESC, `of`
            ROWS UNBOUNDED PRECEDING
        ) AS qtde_acumulada
    FROM odf
),
-- monitor de OC na data de atualizacao mais recente
mon AS (
    SELECT
        m.oc,
        m.linha,
        m.ciclo,
        m.ciclo_atual,
        m.dat_atualizacao
    FROM manufatura.monitor_oc_embraer m
    WHERE m.dat_atualizacao = (
        SELECT MAX(dat_atualizacao)
        FROM manufatura.monitor_oc_embraer
    )
),
c AS (
    SELECT
        efe.pn,
        efe.pem,
        efe.prog,
        efe.status_prazo,
        efe.motivo_falta,
        efe.centro,
        efe.necessidade,
        efe.oc,
        efe.linha,
        efe.qtd,
        efe.qtd_acumulada,
        COALESCE(ofp.possui_objeto_dezena, 0) AS possui_objeto_dezena,
        COALESCE(ofp.possui_of_eft, 0) AS possui_of_eft,
        COALESCE(ofp.qtde_of, 0) AS qtde_of,
        COALESCE(ofp.qtde_of_eft, 0) AS qtde_of_eft,
        ofa.`of`,
        ofa.centrotrabalho,
        ofa.sequencia_producao,
        CASE
            WHEN mon.oc IS NULL OR mon.ciclo IS NULL OR mon.ciclo <= 0 THEN NULL
            ELSE mon.dat_atualizacao + INTERVAL (mon.ciclo - mon.ciclo_atual) DAY
        END AS data_ciclo
    FROM efe
    LEFT JOIN ofp
        ON ofp.pn = efe.pn
    -- OF cuja faixa contem a primeira peca da linha
    LEFT JOIN ofa
        ON ofa.pn = efe.pn
        AND efe.qtd_acumulada - efe.qtd >= ofa.qtde_acumulada - ofa.qtde
        AND efe.qtd_acumulada - efe.qtd < ofa.qtde_acumulada
    LEFT JOIN mon
        ON efe.oc IS NOT NULL
        AND efe.oc <> ''
        AND mon.oc = CAST(efe.oc AS UNSIGNED)
        AND mon.linha = efe.linha
)
SELECT
    c.pn,
    c.pem,
    c.prog,
    c.status_prazo,
    c.motivo_falta,
    c.centro,
    c.necessidade,
    c.oc,
    c.linha,
    c.qtd,
    c.qtd_acumulada,
    c.possui_objeto_dezena,
    c.possui_of_eft,
    c.qtde_of,
    c.qtde_of_eft,
    c.`of`,
    c.centrotrabalho,
    IF(c.qtde_of >= c.qtd_acumulada, 1, 0) AS cobre_falta,
    IF(c.qtde_of_eft >= c.qtd_acumulada, 1, 0) AS acionamento_efetivo,
    CASE
        WHEN c.possui_of_eft = 0 AND c.qtde_of < c.qtd_acumulada THEN 'semof_semplano'
        WHEN c.possui_of_eft = 0 AND c.qtde_of >= c.qtd_acumulada THEN 'comof_semplano'
        WHEN c.qtde_of_eft < c.qtd_acumulada AND c.qtde_of < c.qtd_acumulada THEN 'insuficiente_semof'
        WHEN c.qtde_of_eft < c.qtd_acumulada AND c.qtde_of >= c.qtd_acumulada THEN 'insuficiente_comof'
    END AS tipo_falta,
    c.data_ciclo,
    CASE
        WHEN c.data_ciclo IS NULL THEN 'SEM OF'
        WHEN c.data_ciclo < CURDATE() THEN 'VENCIDO'
        ELSE 'OK'
    END AS ciclo_status,
    c.sequencia_producao,
    CASE
        WHEN COALESCE(c.sequencia_producao, 999999999) < COALESCE((
            SELECT CAST(p.valor AS UNSIGNED)
            FROM config.parametro p
            WHERE p.nome = 'DISPERSAO_CT_SEQ_CORTE'
            LIMIT 1
        ), 120) THEN 'PRE'
        ELSE 'POS'
    END AS fase_manufatura
FROM c;
