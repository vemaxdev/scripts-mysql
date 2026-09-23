-- vw_extrato_faltas_embraer_atual
-- Linhas de manufatura.extrato_faltas_embraer da ultima importacao
-- (atualizado_em = maior atualizado_em da tabela, comparando data e hora).

CREATE OR REPLACE
    ALGORITHM = UNDEFINED
    DEFINER = `vemax`@`%`
    SQL SECURITY DEFINER
VIEW manufatura.vw_extrato_faltas_embraer_atual AS
SELECT
    e.id,
    e.id_origem,
    e.data_extrato,
    e.prog,
    e.centro,
    e.projeto,
    e.ns,
    e.d,
    e.cemb,
    e.origem,
    e.pn,
    e.descricao,
    e.qtd,
    e.pcp_forn,
    e.pcp_solic,
    e.necessidade,
    e.prazo,
    e.apoio,
    e.comn_forn,
    e.oc,
    e.linha,
    e.pem,
    e.status_prazo,
    e.motivo_falta,
    e.ind_crtc,
    e.dat_lmt_embq,
    e.atualizado_em,
    e.usuario_importacao
FROM manufatura.extrato_faltas_embraer e
WHERE e.atualizado_em = (
    SELECT MAX(e2.atualizado_em)
    FROM manufatura.extrato_faltas_embraer e2
);
