-- manufatura.vw_painel_pcp fonte

CREATE OR REPLACE
ALGORITHM = UNDEFINED VIEW `manufatura`.`vw_painel_pcp` AS
select
    `manufatura`.`ordem_fabricacao`.`of` AS `OF`,
    max(`manufatura`.`ordem_fabricacao`.`oc_linha`) AS `OC/linha`,
    max(if((`manufatura`.`nf_entrada`.`chave_de_acesso` is null), 'SEM NF',
        if((`manufatura`.`nf_recebimento`.`chave_de_acesso` is null), 'EM TRANSITO', 'RECEBIDO'))) AS `Rastreio MP`,
    max(if((`af`.`of_da_aplicacao_do_fai` is null), 'OK',
        if((`af`.`validacao_do_fai` is null), 'BLOQUEADO', `af`.`validacao_do_fai`))) AS `FAI`,
    max(`bm`.`status`) AS `metodo_status`,
    max(`bq`.`bloqueado`) AS `qualidade_status`,
    if((max(`contagem_of`.`total_ofs`) = 1), 'Única',
        concat('Parcial (1/', max(`contagem_of`.`total_ofs`), ')')) AS `Quebra`,
    max(if((`manufatura`.`ordem_fabricacao`.`status_of` is null),
        if((`manufatura`.`pedido`.`status_poack` = 'FIRME'), 'PLANEJADO', 'PREVISTO'),
        `manufatura`.`ordem_fabricacao`.`status_of`)) AS `Status OF`,
    max(`manufatura`.`ordem_fabricacao`.`qtde`) AS `Quantidade`,
    max(`manufatura`.`ordem_fabricacao`.`pn`) AS `PN`,
    max(round((if((`manufatura`.`item_poack_atual`.`preco_bruto` is null),
        `manufatura`.`item_outro_cliente`.`vunit`,
        `manufatura`.`item_poack_atual`.`preco_bruto`) * `manufatura`.`ordem_fabricacao`.`qtde`), 2)) AS `Total OF`,
    max(`manufatura`.`vw_ultima_data_fluxo`.`centrotrabalho`) AS `Centro de trabalho`,
    (to_days(curdate()) - to_days(max(`manufatura`.`fluxo`.`datafluxo`))) AS `Aging`,
    max(`manufatura`.`ordem_fabricacao`.`descricao`) AS `Descrição`,
    max(`ps`.`faixa`) AS `Faixa`,
    max(`manufatura`.`objeto_dezena_atual`.`sts`) AS `STS`,
    max(`manufatura`.`ciclo_remessa_poack_atual`.`dias_cvrv`) AS `dias_cvrv`,
    max(`manufatura`.`ciclo_remessa_poack_atual`.`status`) AS `status_poack_atual`,
    cast(max(`manufatura`.`item_poack_atual`.`material`) as char charset utf8mb4) AS `Cód Produto`,
    date_format(max(str_to_date(`manufatura`.`item_poack_atual`.`dt_promessa`, '%Y-%m-%d')), '%d/%m/%Y') AS `Data promessa`,
    format(max(`manufatura`.`item_poack_atual`.`ciclo`), 0) AS `Ciclo`,
    max(`manufatura`.`ciclo_remessa_poack_atual`.`delta_ciclo`) AS `Delta ciclo`,
    max(`manufatura`.`ciclo_remessa_poack_atual`.`delta_remessa`) AS `Delta remessa`,
    max(date_format(`manufatura`.`ciclo_remessa_poack_atual`.`data_ciclo`, '%d/%m/%Y')) AS `Data ciclo`,
    max(date_format(`manufatura`.`item_poack_atual`.`dt_remessa`, '%d/%m/%Y')) AS `Data_remessa`,
    max(`manufatura`.`item_poack_atual`.`1a_nf`) AS `Aging primeira NF`,
    max(`manufatura`.`objeto_dezena_atual`.`prio_vmx`) AS `Prioridade`,
    max(`manufatura`.`objeto_dezena_atual`.`sep`) AS `SEP`,
    max(`manufatura`.`item_poack_atual`.`centro`) AS `CT Centro`,
    replace(max(`manufatura`.`nf_entrada`.`codigo_mp`), ' 00:00:00', '') AS `Cód MP`,
    max(`manufatura`.`pedido`.`cliente`) AS `Cliente`,
    max(`vemax`.`fiscal_notas_emitidas`.`nf_saida`) AS `NF saida`,
    max(date_format(`manufatura`.`totvs_sd2`.`emissao`, '%d/%m/%Y')) AS `Data NF saida`,
    max(`manufatura`.`item_poack_atual`.`ct_descricao`) AS `Descrição CT`,
    max(date_format(`manufatura`.`objeto_dezena_atual`.`data_rota`, '%d/%m/%Y')) AS `Data_rota`,
    date_format((
        select `c`.`data_limite`
        from `manufatura`.`controle_data_limite_fluxo` `c`
        where (`c`.`id_fluxo` = `fluxo_max`.`id_fluxo`)
        order by `c`.`id` desc
        limit 1), '%d/%m/%Y') AS `Data Limite`,
    date_format(max(`manufatura`.`objeto_dezena_atual`.`de_simul`), '%d/%m/%Y') AS `data_simulada`,
    max(`manufatura`.`centro_trabalho`.`gestor`) AS `Gestor`,
    (to_days(ifnull((
        select `c`.`data_limite`
        from `manufatura`.`controle_data_limite_fluxo` `c`
        where (`c`.`id_fluxo` = `fluxo_max`.`id_fluxo`)
        order by `c`.`id` desc
        limit 1),
        (curdate() + interval ifnull(max(`manufatura`.`aging_padrao`.`aging`), 0) day))) - to_days(curdate())) AS `Dias Limite`,
    max(`manufatura`.`pn_situacao_cobertura`.`situacao`) AS `Situacao PN Cob.`,
    max(`manufatura`.`pn_extrato_cobertura`.`categoria`) AS `Situacao OF Cob.`,
    max(`manufatura`.`pn_situacao_cobertura`.`saldo_inicial`) AS `Qtde Cobertura`,
    max(`manufatura`.`tempos_manufatura_pn`.`grupo`) AS `grupo`,
    replace(format(max((`manufatura`.`tempos_manufatura_pn`.`tempo_cnc_geral` * `manufatura`.`ordem_fabricacao`.`qtde`)), 2), '.', ',') AS `Tempo CNC`,
    replace(format(max((`manufatura`.`tempos_manufatura_pn`.`tempo_torno_geral` * `manufatura`.`ordem_fabricacao`.`qtde`)), 2), '.', ',') AS `Tempo TORNO`,
    (case
        when (max(`af_ultimo`.`validacao_do_fai`) = 'Aprovada') then ''
        else (case when (max(`af_ultimo`.`validacao_do_fai`) is null) then 'N/D' else '⛔' end)
    end) AS `D`,
    (case
        when (count(`bm`.`pn_ref`) = 0) then ''
        when (sum((case when ((`bm`.`status` <> 'LIBERADO') or (`bm`.`status` is null)) then 1 else 0 end)) > 0) then '⛔'
        else ''
    end) AS `M`,
    (case
        when (count(`bq`.`pn_ref`) = 0) then ''
        when (sum((case when ((`bq`.`bloqueado` <> 'LIBERADO') or (`bq`.`bloqueado` is null)) then 1 else 0 end)) > 0) then '⛔'
        else ''
    end) AS `Q`,
    max(if((`af`.`of_da_aplicacao_do_fai` = `manufatura`.`ordem_fabricacao`.`of`), '✅', '')) AS `FAI_`,
    max(`manufatura`.`objeto_dezena_atual`.`cobertura_dinamica`) AS `cobertura_dinamica`,
    max(`ps`.`prio_cong`) AS `Prio Cong`,
    max(`ps`.`prio_din`) AS `Prio Din`,
    max(`ps`.`prio_falta`) AS `Prio Falta`,
    max(`ps`.`prio_acion`) AS `Prio Acion`,
    max(`snf`.`status_nf`) AS `Status NF`,
    max(`pt`.`tipo`) AS `tipo`,
    date_format(max(`apv`.`data_entrega`), '%d/%m/%Y') AS `ultima_data_tratador`,
    date_format(max(`trat`.`ultima_emissao_trat`), '%d/%m/%Y') AS `ultima_emissao_trat`,
    max(`trat`.`nome_trat`) AS `nome_trat`,
    max(`manufatura`.`centro_trabalho`.`pre_usinagem`) AS `pre_usinagem`,
    max(`manufatura`.`centro_trabalho`.`grupo_bi`) AS `grupo_bi`
from `manufatura`.`ordem_fabricacao`
left join `manufatura`.`tempos_manufatura_pn`
    on `manufatura`.`ordem_fabricacao`.`pn` = `manufatura`.`tempos_manufatura_pn`.`part_number`
left join `manufatura`.`nf_entrada`
    on `manufatura`.`ordem_fabricacao`.`oc_linha` = `manufatura`.`nf_entrada`.`oc_linha`
left join `manufatura`.`nf_recebimento`
    on `manufatura`.`nf_entrada`.`chave_de_acesso` = `manufatura`.`nf_recebimento`.`chave_de_acesso`
left join `manufatura`.`aprovacao_fai` `af`
    on `manufatura`.`ordem_fabricacao`.`pn` = `af`.`pn`
left join `manufatura`.`bloqueio_metodo` `bm`
    on `manufatura`.`ordem_fabricacao`.`pn` = `bm`.`pn_ref`
left join `manufatura`.`bloqueio_qualidade` `bq`
    on `manufatura`.`ordem_fabricacao`.`pn` = `bq`.`pn_ref`
left join `manufatura`.`item_poack_atual`
    on `manufatura`.`ordem_fabricacao`.`oc` = `manufatura`.`item_poack_atual`.`po`
    and `manufatura`.`ordem_fabricacao`.`linha` = `manufatura`.`item_poack_atual`.`linha`
left join `manufatura`.`item_outro_cliente`
    on `manufatura`.`ordem_fabricacao`.`oc_linha` = `manufatura`.`item_outro_cliente`.`oc_linha`
left join `manufatura`.`fluxo`
    on `manufatura`.`ordem_fabricacao`.`of` = `manufatura`.`fluxo`.`ordemfabricacao`
left join `manufatura`.`objeto_dezena_atual`
    on `manufatura`.`ordem_fabricacao`.`of` = `manufatura`.`objeto_dezena_atual`.`of`
left join `manufatura`.`ciclo_remessa_poack_atual`
    on `manufatura`.`ordem_fabricacao`.`oc_linha` = `manufatura`.`ciclo_remessa_poack_atual`.`oc_linha`
left join `manufatura`.`vw_ultima_data_fluxo`
    on `manufatura`.`fluxo`.`ID` = `manufatura`.`vw_ultima_data_fluxo`.`ID`
left join `vemax`.`fiscal_notas_emitidas`
    on `manufatura`.`ordem_fabricacao`.`of` = `vemax`.`fiscal_notas_emitidas`.`of`
join `manufatura`.`pedido`
    on `manufatura`.`ordem_fabricacao`.`pedido` = `manufatura`.`pedido`.`pedido`
left join `manufatura`.`totvs_sd2`
    on `manufatura`.`ordem_fabricacao`.`of` = `manufatura`.`totvs_sd2`.`of`
    and `manufatura`.`totvs_sd2`.`cliente` in (6, 7, 8)
left join `manufatura`.`centro_trabalho`
    on `manufatura`.`vw_ultima_data_fluxo`.`centrotrabalho` = `manufatura`.`centro_trabalho`.`ct`
left join `manufatura`.`grupo_centro_trabalho`
    on `manufatura`.`centro_trabalho`.`id_grupo` = `manufatura`.`grupo_centro_trabalho`.`id`
left join `manufatura`.`aging_padrao`
    on `manufatura`.`grupo_centro_trabalho`.`id` = `manufatura`.`aging_padrao`.`id_grupo`
left join `manufatura`.`pn_situacao_cobertura`
    on `manufatura`.`ordem_fabricacao`.`pn` = `manufatura`.`pn_situacao_cobertura`.`pn`
left join `manufatura`.`pn_extrato_cobertura`
    on `manufatura`.`ordem_fabricacao`.`pn` = `manufatura`.`pn_extrato_cobertura`.`pn`
left join (
    select
        `manufatura`.`aprovacao_fai`.`pn` AS `pn`,
        max(`manufatura`.`aprovacao_fai`.`ID`) AS `max_id`
    from `manufatura`.`aprovacao_fai`
    group by `manufatura`.`aprovacao_fai`.`pn`) `af_max`
    on `manufatura`.`ordem_fabricacao`.`pn` = `af_max`.`pn`
left join `manufatura`.`aprovacao_fai` `af_ultimo`
    on `af_ultimo`.`pn` = `af_max`.`pn`
    and `af_ultimo`.`ID` = `af_max`.`max_id`
left join (
    select
        `manufatura`.`fluxo`.`ordemfabricacao` AS `ordemfabricacao`,
        max(`manufatura`.`fluxo`.`ID`) AS `id_fluxo`
    from `manufatura`.`fluxo`
    group by `manufatura`.`fluxo`.`ordemfabricacao`) `fluxo_max`
    on `fluxo_max`.`ordemfabricacao` = `manufatura`.`ordem_fabricacao`.`of`
left join (
    select
        `manufatura`.`ordem_fabricacao`.`oc_linha` AS `oc_linha`,
        count(0) AS `total_ofs`
    from `manufatura`.`ordem_fabricacao`
    group by `manufatura`.`ordem_fabricacao`.`oc_linha`) `contagem_of`
    on `contagem_of`.`oc_linha` = `manufatura`.`ordem_fabricacao`.`oc_linha`
left join `manufatura`.`vw_prio_status_of` `ps`
    on `ps`.`of` = `manufatura`.`ordem_fabricacao`.`of`
left join `manufatura`.`vw_of_status_nf` `snf`
    on `snf`.`of` = `manufatura`.`ordem_fabricacao`.`of`
left join (
    select
        `manufatura`.`pn_tratamento`.`pn` AS `pn`,
        max(`manufatura`.`pn_tratamento`.`tipo`) AS `tipo`
    from `manufatura`.`pn_tratamento`
    group by `manufatura`.`pn_tratamento`.`pn`) `pt`
    on `pt`.`pn` = `manufatura`.`ordem_fabricacao`.`pn`
left join (
    select
        `x`.`of` AS `of`,
        `x`.`emissao` AS `ultima_emissao_trat`,
        `x`.`nome` AS `nome_trat`,
        `x`.`oc_linha` AS `oc_linha_trat`
    from (
        select
            `s`.`of` AS `of`,
            `s`.`emissao` AS `emissao`,
            `t`.`nome` AS `nome`,
            concat(nullif(`s`.`numpedcomp`, ''), '/', `s`.`itempedcom`) AS `oc_linha`,
            row_number() over (partition by `s`.`of` order by `s`.`emissao` desc, `s`.`ID` desc) AS `rn`
        from `manufatura`.`totvs_sd2` `s`
        join `manufatura`.`tratador` `t`
            on `t`.`fornecedor` = `s`.`cliente`) `x`
    where `x`.`rn` = 1) `trat`
    on `trat`.`of` = `manufatura`.`ordem_fabricacao`.`of`
left join (
    select
        `y`.`oc_linha` AS `oc_linha`,
        `y`.`data_entrega` AS `data_entrega`
    from (
        select
            `a`.`oc_linha` AS `oc_linha`,
            `a`.`data_entrega` AS `data_entrega`,
            row_number() over (partition by `a`.`oc_linha` order by `a`.`data_alteracao` desc, `a`.`ID` desc) AS `rn`
        from `manufatura`.`alteracao_poack_vemax` `a`) `y`
    where `y`.`rn` = 1) `apv`
    on `apv`.`oc_linha` = `trat`.`oc_linha_trat`
where
    (
        (lower(`manufatura`.`pedido`.`cliente`) like '%embraer%'
            and `manufatura`.`item_poack_atual`.`action` in ('LIDO', 'NFE'))
        or (not (lower(`manufatura`.`pedido`.`cliente`) like '%embraer%')
            and `manufatura`.`ordem_fabricacao`.`status_of` is null
            and `manufatura`.`vw_ultima_data_fluxo`.`centrotrabalho` <> '125-Cliente OUTROS')
    )
    and coalesce(`manufatura`.`ordem_fabricacao`.`status_of`, '') <> 'EXCLUIDA'
group by
    `manufatura`.`ordem_fabricacao`.`of`,
    `fluxo_max`.`id_fluxo`;
