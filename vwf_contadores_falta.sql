SELECT efe.pn, efe.qtd_falta,
    MAX(IF(EXISTS (
        SELECT 1
        FROM manufatura.objeto_dezena_atual oda
        WHERE oda.`of` = odf.`of`
    ), 1, 0)) AS possui_objeto_dezena,
    MIN(IF(EXISTS (
        SELECT 1
        FROM manufatura.objeto_dezena_atual oda
        WHERE oda.`of` = odf.`of`
        AND oda.acionamento_direto LIKE '%EFT%'
    ), 1, 0)) AS acionamento_efetivo,
    sum(odf.qtde) AS qtde_of,
    IF(sum(odf.qtde) >= efe.qtd_falta, 1, 0) AS cobre_falta
FROM (
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
WHERE EXISTS (
    SELECT 1
    FROM manufatura.item_poack_atual ipa
    WHERE CONCAT(ipa.po, '/', LPAD(ipa.linha, 5, '0')) = odf.oc_linha
    AND ipa.action = 'LIDO'
)
GROUP BY efe.pn, efe.qtd_falta
