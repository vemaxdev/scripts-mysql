CREATE ALGORITHM=UNDEFINED DEFINER=`vemax`@`%` SQL SECURITY DEFINER VIEW `pbi`.`vwf_aderencia` AS

SELECT
    IPA.po,
    IPA.linha,
    ODF.`of`,
    IPA.part_number,
    CONVERT(IPA.ct_origem, SIGNED) AS ct_embraer_poack,
    VWU.centrotrabalho,
    CT.ct_embraer AS ct_embraer_ordem,
    IF(CONVERT(IPA.ct_origem, SIGNED) = CT.ct_embraer, 'ADERENTE', 'DISCORDANTE') AS status_aderencia,
    IF(NFT.oc_linha IS NOT NULL, 'SIM', 'NAO') AS possui_nota_tratador
FROM manufatura.item_poack_atual IPA
LEFT JOIN manufatura.ordem_fabricacao ODF
    ON CONCAT(IPA.po, '/', LPAD(IPA.linha, 5, '0')) = ODF.oc_linha
    AND ODF.id = (
        SELECT MAX(O2.id)
        FROM manufatura.ordem_fabricacao O2
        WHERE O2.oc_linha = CONCAT(IPA.po, '/', LPAD(IPA.linha, 5, '0'))
    )
LEFT JOIN manufatura.vw_ultima_data_fluxo VWU
    ON VWU.ordemfabricacao = ODF.`of`
LEFT JOIN manufatura.centro_trabalho CT
    ON CT.ct = VWU.centrotrabalho
LEFT JOIN manufatura.nf_entrada_tratador NFT
    ON NFT.oc_linha = CONCAT(IPA.po, '/', LPAD(IPA.linha, 5, '0'))
WHERE IPA.action = 'LIDO';
